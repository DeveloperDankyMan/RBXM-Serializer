--!strict
--[[
	Attributes.luau

	`AttributesSerialize` is a plain String property holding its own little
	binary blob. It is *not* readable from Lua, so to round-trip attributes we
	build and parse the blob ourselves from `GetAttributes` / `SetAttribute`.

	Layout:
		count : u32
		repeated count times:
			name  : u32 length + bytes
			type  : u8
			value : depends on type

	The type IDs here are their own numbering — they do not match the model
	format's type IDs (String is 0x01 there but 0x02 here).
]]

local Stream = require(script.Parent.Stream)

type Stream = Stream.Stream

local Attributes = {}

local T = {
	String = 0x02,
	Bool = 0x03,
	Int32 = 0x04,
	Float32 = 0x05,
	Float64 = 0x06,
	UDim = 0x09,
	UDim2 = 0x0A,
	BrickColor = 0x0E,
	Color3 = 0x0F,
	Vector2 = 0x10,
	Vector3 = 0x11,
	CFrame = 0x14,
	EnumItem = 0x15,
	NumberSequence = 0x17,
	ColorSequence = 0x19,
	NumberRange = 0x1B,
	Rect = 0x1C,
	Font = 0x21,
}
Attributes.TypeId = T

local DataTypes = require(script.Parent.DataTypes)
local ROTATION_MATRIX = DataTypes.ROTATION_MATRIX

local function readString(s: Stream): string
	local len = s:u32()
	return if len > 0 then s:str(len) else ""
end

local function writeString(s: Stream, str: string)
	s:wu32(#str)
	s:wstr(str)
end

-- ------------------------------------------------------------------ decode

--[[ Parses an AttributesSerialize blob into a { [string]: any } map. ]]
function Attributes.decode(blob: string): { [string]: any }
	local out = {}
	if #blob < 4 then
		return out
	end

	local s = Stream.fromString(blob)
	local ok, err = pcall(function()
		local count = s:u32()
		for _ = 1, count do
			local name = readString(s)
			local ty = s:u8()

			if ty == T.String then
				out[name] = readString(s)
			elseif ty == T.Bool then
				out[name] = s:u8() ~= 0
			elseif ty == T.Int32 then
				out[name] = s:i32()
			elseif ty == T.Float32 then
				out[name] = s:f32()
			elseif ty == T.Float64 then
				out[name] = s:f64()
			elseif ty == T.UDim then
				out[name] = UDim.new(s:f32(), s:i32())
			elseif ty == T.UDim2 then
				local xs, xo = s:f32(), s:i32()
				local ys, yo = s:f32(), s:i32()
				out[name] = UDim2.new(xs, xo, ys, yo)
			elseif ty == T.BrickColor then
				out[name] = BrickColor.new(s:u32())
			elseif ty == T.Color3 then
				out[name] = Color3.new(s:f32(), s:f32(), s:f32())
			elseif ty == T.Vector2 then
				out[name] = Vector2.new(s:f32(), s:f32())
			elseif ty == T.Vector3 then
				out[name] = Vector3.new(s:f32(), s:f32(), s:f32())
			elseif ty == T.CFrame then
				local px, py, pz = s:f32(), s:f32(), s:f32()
				local rotId = s:u8()
				local m
				if rotId == 0 then
					m = { s:f32(), s:f32(), s:f32(), s:f32(), s:f32(), s:f32(), s:f32(), s:f32(), s:f32() }
					-- stored as XVector, YVector, ZVector (column vectors)
					out[name] = CFrame.fromMatrix(
						Vector3.new(px, py, pz),
						Vector3.new(m[1], m[2], m[3]),
						Vector3.new(m[4], m[5], m[6]),
						Vector3.new(m[7], m[8], m[9])
					)
				else
					m = ROTATION_MATRIX[rotId]
					out[name] = CFrame.new(
						px, py, pz,
						m[1], m[2], m[3],
						m[4], m[5], m[6],
						m[7], m[8], m[9]
					)
				end
			elseif ty == T.EnumItem then
				local enumName = readString(s)
				local value = s:u32()
				local okEnum, item = pcall(function()
					for _, e in (Enum :: any)[enumName]:GetEnumItems() do
						if e.Value == value then
							return e
						end
					end
					return nil
				end)
				out[name] = if okEnum then item else nil
			elseif ty == T.NumberSequence then
				local n = s:u32()
				local kps = table.create(n)
				for i = 1, n do
					local envelope, t, v = s:f32(), s:f32(), s:f32()
					kps[i] = NumberSequenceKeypoint.new(t, v, envelope)
				end
				out[name] = if n >= 2 then NumberSequence.new(kps) else NumberSequence.new(0)
			elseif ty == T.ColorSequence then
				local n = s:u32()
				local kps = table.create(n)
				for i = 1, n do
					s:f32() -- envelope, always zero
					local t = s:f32()
					kps[i] = ColorSequenceKeypoint.new(t, Color3.new(s:f32(), s:f32(), s:f32()))
				end
				out[name] = if n >= 2 then ColorSequence.new(kps) else ColorSequence.new(Color3.new())
			elseif ty == T.NumberRange then
				out[name] = NumberRange.new(s:f32(), s:f32())
			elseif ty == T.Rect then
				out[name] = Rect.new(s:f32(), s:f32(), s:f32(), s:f32())
			elseif ty == T.Font then
				local weight = s:u16()
				local style = s:u8()
				local family = readString(s)
				readString(s) -- CachedFaceId
				local weightEnum = Enum.FontWeight.Regular
				for _, item in Enum.FontWeight:GetEnumItems() do
					if item.Value == weight then
						weightEnum = item
						break
					end
				end
				local okFont, font = pcall(
					Font.new,
					family,
					weightEnum,
					if style == 1 then Enum.FontStyle.Italic else Enum.FontStyle.Normal
				)
				out[name] = if okFont then font else nil
			else
				error(`Attributes: unknown attribute type id 0x{string.format("%02x", ty)} for "{name}"`)
			end
		end
	end)

	if not ok then
		warn(`[RbxmSerializer] attribute blob could not be fully parsed: {err}`)
	end
	return out
end

-- ------------------------------------------------------------------ encode

local ROTATION_LOOKUP: { [string]: number } = {}
do
	local function key(m: { number }): string
		local p = table.create(9)
		for i = 1, 9 do
			p[i] = if math.abs(m[i]) < 1e-5 then "0" else string.format("%d", math.round(m[i]))
		end
		return table.concat(p, ",")
	end
	for id, m in ROTATION_MATRIX do
		local k = key(m)
		if ROTATION_LOOKUP[k] == nil then
			ROTATION_LOOKUP[k] = id
		end
	end
	Attributes._rotationKey = key
end

--[[ Builds an AttributesSerialize blob from a { [string]: any } map. ]]
function Attributes.encode(attrs: { [string]: any }): string
	local names = {}
	for name in attrs do
		table.insert(names, name)
	end
	table.sort(names)

	if #names == 0 then
		return ""
	end

	local s = Stream.new(256)
	s:wu32(#names)

	for _, name in names do
		local value = attrs[name]
		local ty = typeof(value)

		writeString(s, name)

		if ty == "string" then
			s:wu8(T.String)
			writeString(s, value)
		elseif ty == "boolean" then
			s:wu8(T.Bool)
			s:wu8(if value then 1 else 0)
		elseif ty == "number" then
			s:wu8(T.Float64)
			s:wf64(value)
		elseif ty == "UDim" then
			s:wu8(T.UDim)
			s:wf32(value.Scale)
			s:wi32(value.Offset)
		elseif ty == "UDim2" then
			s:wu8(T.UDim2)
			s:wf32(value.X.Scale)
			s:wi32(value.X.Offset)
			s:wf32(value.Y.Scale)
			s:wi32(value.Y.Offset)
		elseif ty == "BrickColor" then
			s:wu8(T.BrickColor)
			s:wu32(value.Number)
		elseif ty == "Color3" then
			s:wu8(T.Color3)
			s:wf32(value.R)
			s:wf32(value.G)
			s:wf32(value.B)
		elseif ty == "Vector2" then
			s:wu8(T.Vector2)
			s:wf32(value.X)
			s:wf32(value.Y)
		elseif ty == "Vector3" then
			s:wu8(T.Vector3)
			s:wf32(value.X)
			s:wf32(value.Y)
			s:wf32(value.Z)
		elseif ty == "CFrame" then
			s:wu8(T.CFrame)
			local px, py, pz, r00, r01, r02, r10, r11, r12, r20, r21, r22 = value:GetComponents()
			s:wf32(px)
			s:wf32(py)
			s:wf32(pz)
			-- axis-aligned check against the rotation table
			local m = { r00, r01, r02, r10, r11, r12, r20, r21, r22 }
			local aligned = true
			for i = 1, 9 do
				local a = math.abs(m[i])
				if a > 1e-5 and math.abs(a - 1) > 1e-5 then
					aligned = false
					break
				end
			end
			local id = if aligned then ROTATION_LOOKUP[Attributes._rotationKey(m)] else nil
			if id then
				s:wu8(id)
			else
				s:wu8(0)
				-- XVector, YVector, ZVector
				local x, y, z = value.XVector, value.YVector, value.ZVector
				s:wf32(x.X) s:wf32(x.Y) s:wf32(x.Z)
				s:wf32(y.X) s:wf32(y.Y) s:wf32(y.Z)
				s:wf32(z.X) s:wf32(z.Y) s:wf32(z.Z)
			end
		elseif ty == "EnumItem" then
			s:wu8(T.EnumItem)
			writeString(s, tostring(value.EnumType))
			s:wu32(value.Value)
		elseif ty == "NumberSequence" then
			s:wu8(T.NumberSequence)
			local kps = value.Keypoints
			s:wu32(#kps)
			for _, kp in kps do
				s:wf32(kp.Envelope)
				s:wf32(kp.Time)
				s:wf32(kp.Value)
			end
		elseif ty == "ColorSequence" then
			s:wu8(T.ColorSequence)
			local kps = value.Keypoints
			s:wu32(#kps)
			for _, kp in kps do
				s:wf32(0)
				s:wf32(kp.Time)
				s:wf32(kp.Value.R)
				s:wf32(kp.Value.G)
				s:wf32(kp.Value.B)
			end
		elseif ty == "NumberRange" then
			s:wu8(T.NumberRange)
			s:wf32(value.Min)
			s:wf32(value.Max)
		elseif ty == "Rect" then
			s:wu8(T.Rect)
			s:wf32(value.Min.X)
			s:wf32(value.Min.Y)
			s:wf32(value.Max.X)
			s:wf32(value.Max.Y)
		elseif ty == "Font" then
			s:wu8(T.Font)
			s:wu16(value.Weight.Value)
			s:wu8(if value.Style == Enum.FontStyle.Italic then 1 else 0)
			writeString(s, value.Family)
			writeString(s, "")
		else
			error(`Attributes: cannot serialize attribute "{name}" of type {ty}`)
		end
	end

	return s:tostring()
end

return Attributes
