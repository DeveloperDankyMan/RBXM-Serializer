--!strict
--!native
--[[
	DataTypes.luau

	One reader and one writer per binary type ID. Every function works on a
	*whole column* of values at once, because that is how the PROP chunk
	stores them (and it is what makes the interleaving transforms possible).

		DataTypes.read[typeId](stream, count)  -> { value }
		DataTypes.write[typeId](stream, values)

	Values are represented as native Roblox datatypes wherever one exists.
	Three types are represented indirectly and resolved by the Decoder:

		Referent      -> number  (referent id, -1 = null)
		SharedString  -> number  (1-based index into the SSTR table)
		Content       -> table   ({ sourceType, uri, ref })
]]

local Stream = require(script.Parent.Stream)
local Transforms = require(script.Parent.Transforms)

type Stream = Stream.Stream

local DataTypes = {}

local TypeId = {
	String = 0x01,
	Bool = 0x02,
	Int32 = 0x03,
	Float32 = 0x04,
	Float64 = 0x05,
	UDim = 0x06,
	UDim2 = 0x07,
	Ray = 0x08,
	Faces = 0x09,
	Axes = 0x0A,
	BrickColor = 0x0B,
	Color3 = 0x0C,
	Vector2 = 0x0D,
	Vector3 = 0x0E,
	CFrame = 0x10,
	Quaternion = 0x11,
	Enum = 0x12,
	Referent = 0x13,
	Vector3int16 = 0x14,
	NumberSequence = 0x15,
	ColorSequence = 0x16,
	NumberRange = 0x17,
	Rect = 0x18,
	PhysicalProperties = 0x19,
	Color3uint8 = 0x1A,
	Int64 = 0x1B,
	SharedString = 0x1C,
	Bytecode = 0x1D,
	OptionalCFrame = 0x1E,
	UniqueId = 0x1F,
	Font = 0x20,
	SecurityCapabilities = 0x21,
	Content = 0x22,
}
DataTypes.TypeId = TypeId

local TypeName = {}
for name, id in TypeId do
	TypeName[id] = name
end
DataTypes.TypeName = TypeName

-- ------------------------------------------------- CFrame special rotations

-- id -> { rx, ry, rz } in degrees, applied Y -> X -> Z
local ROTATION_IDS: { [number]: { number } } = {
	[0x02] = { 0, 0, 0 },
	[0x03] = { 90, 0, 0 },
	[0x05] = { 0, 180, 180 },
	[0x06] = { -90, 0, 0 },
	[0x07] = { 0, 180, 90 },
	[0x09] = { 0, 90, 90 },
	[0x0A] = { 0, 0, 90 },
	[0x0C] = { 0, -90, 90 },
	[0x0D] = { -90, -90, 0 },
	[0x0E] = { 0, -90, 0 },
	[0x10] = { 90, -90, 0 },
	[0x11] = { 0, 90, 180 },
	[0x14] = { 0, 180, 0 },
	[0x15] = { -90, -180, 0 },
	[0x17] = { 0, 0, 180 },
	[0x18] = { 90, 180, 0 },
	[0x19] = { 0, 0, -90 },
	[0x1B] = { 0, -90, -90 },
	[0x1C] = { 0, -180, -90 },
	[0x1E] = { 0, 90, -90 },
	[0x1F] = { 90, 90, 0 },
	[0x20] = { 0, 90, 0 },
	[0x22] = { -90, 90, 0 },
	[0x23] = { 0, -90, 180 },
}

local ROTATION_MATRIX: { [number]: { number } } = {}
local ROTATION_LOOKUP: { [string]: number } = {}

local function matrixKey(m: { number }): string
	local parts = table.create(9)
	for i = 1, 9 do
		-- axis-aligned rotations are exactly 0, 1 or -1 after rounding
		local v = m[i]
		parts[i] = if math.abs(v) < 1e-5 then "0" else string.format("%d", math.round(v))
	end
	return table.concat(parts, ",")
end

do
	local rad = math.rad
	for id, angles in ROTATION_IDS do
		local cf = CFrame.fromEulerAnglesYXZ(rad(angles[1]), rad(angles[2]), rad(angles[3]))
		local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
		local m = { r00, r01, r02, r10, r11, r12, r20, r21, r22 }
		ROTATION_MATRIX[id] = m
		local key = matrixKey(m)
		if ROTATION_LOOKUP[key] == nil then
			ROTATION_LOOKUP[key] = id
		end
	end
end

local function isAxisAligned(m: { number }): boolean
	for i = 1, 9 do
		local a = math.abs(m[i])
		if a > 1e-5 and math.abs(a - 1) > 1e-5 then
			return false
		end
	end
	return true
end

DataTypes.ROTATION_IDS = ROTATION_IDS
DataTypes.ROTATION_MATRIX = ROTATION_MATRIX

-- -------------------------------------------------------------- readers/writers

local read: { [number]: (Stream, number) -> { any } } = {}
local write: { [number]: (Stream, { any }) -> () } = {}
DataTypes.read = read
DataTypes.write = write

-- String (0x01) and Bytecode (0x1D) ---------------------------------------
read[TypeId.String] = function(s, count)
	local out = table.create(count)
	for i = 1, count do
		local len = s:u32()
		out[i] = if len > 0 then s:str(len) else ""
	end
	return out
end

write[TypeId.String] = function(s, values)
	for _, v in values do
		local str = tostring(v)
		s:wu32(#str)
		s:wstr(str)
	end
end

read[TypeId.Bytecode] = read[TypeId.String]
write[TypeId.Bytecode] = write[TypeId.String]

-- Bool (0x02) -------------------------------------------------------------
read[TypeId.Bool] = function(s, count)
	local out = table.create(count)
	for i = 1, count do
		out[i] = s:u8() ~= 0
	end
	return out
end

write[TypeId.Bool] = function(s, values)
	for _, v in values do
		s:wu8(if v then 1 else 0)
	end
end

-- Int32 (0x03) ------------------------------------------------------------
read[TypeId.Int32] = function(s, count)
	return Transforms.readInterleavedI32(s, count)
end

write[TypeId.Int32] = function(s, values)
	Transforms.writeInterleavedI32(s, values :: any)
end

-- Float32 (0x04) ----------------------------------------------------------
read[TypeId.Float32] = function(s, count)
	return Transforms.readInterleavedF32(s, count)
end

write[TypeId.Float32] = function(s, values)
	Transforms.writeInterleavedF32(s, values :: any)
end

-- Float64 (0x05) ----------------------------------------------------------
read[TypeId.Float64] = function(s, count)
	local out = table.create(count)
	for i = 1, count do
		out[i] = s:f64()
	end
	return out
end

write[TypeId.Float64] = function(s, values)
	for _, v in values do
		s:wf64(v)
	end
end

-- UDim (0x06) -------------------------------------------------------------
read[TypeId.UDim] = function(s, count)
	local scale = Transforms.readInterleavedF32(s, count)
	local offset = Transforms.readInterleavedI32(s, count)
	local out = table.create(count)
	for i = 1, count do
		out[i] = UDim.new(scale[i], offset[i])
	end
	return out
end

write[TypeId.UDim] = function(s, values)
	local n = #values
	local scale, offset = table.create(n), table.create(n)
	for i = 1, n do
		local v = values[i] :: UDim
		scale[i] = v.Scale
		offset[i] = v.Offset
	end
	Transforms.writeInterleavedF32(s, scale)
	Transforms.writeInterleavedI32(s, offset)
end

-- UDim2 (0x07) ------------------------------------------------------------
read[TypeId.UDim2] = function(s, count)
	local xs = Transforms.readInterleavedF32(s, count)
	local ys = Transforms.readInterleavedF32(s, count)
	local xo = Transforms.readInterleavedI32(s, count)
	local yo = Transforms.readInterleavedI32(s, count)
	local out = table.create(count)
	for i = 1, count do
		out[i] = UDim2.new(xs[i], xo[i], ys[i], yo[i])
	end
	return out
end

write[TypeId.UDim2] = function(s, values)
	local n = #values
	local xs, ys, xo, yo = table.create(n), table.create(n), table.create(n), table.create(n)
	for i = 1, n do
		local v = values[i] :: UDim2
		xs[i] = v.X.Scale
		ys[i] = v.Y.Scale
		xo[i] = v.X.Offset
		yo[i] = v.Y.Offset
	end
	Transforms.writeInterleavedF32(s, xs)
	Transforms.writeInterleavedF32(s, ys)
	Transforms.writeInterleavedI32(s, xo)
	Transforms.writeInterleavedI32(s, yo)
end

-- Ray (0x08) --------------------------------------------------------------
read[TypeId.Ray] = function(s, count)
	local out = table.create(count)
	for i = 1, count do
		local ox, oy, oz = s:f32(), s:f32(), s:f32()
		local dx, dy, dz = s:f32(), s:f32(), s:f32()
		out[i] = Ray.new(Vector3.new(ox, oy, oz), Vector3.new(dx, dy, dz))
	end
	return out
end

write[TypeId.Ray] = function(s, values)
	for _, v in values do
		local r = v :: Ray
		s:wf32(r.Origin.X)
		s:wf32(r.Origin.Y)
		s:wf32(r.Origin.Z)
		s:wf32(r.Direction.X)
		s:wf32(r.Direction.Y)
		s:wf32(r.Direction.Z)
	end
end

-- Faces (0x09) ------------------------------------------------------------
local FACE_ORDER = {
	Enum.NormalId.Front,
	Enum.NormalId.Bottom,
	Enum.NormalId.Left,
	Enum.NormalId.Back,
	Enum.NormalId.Top,
	Enum.NormalId.Right,
}

read[TypeId.Faces] = function(s, count)
	local out = table.create(count)
	for i = 1, count do
		local bits = s:u8()
		local ids = {}
		for b = 0, 5 do
			if bit32.band(bit32.rshift(bits, b), 1) == 1 then
				table.insert(ids, FACE_ORDER[b + 1])
			end
		end
		out[i] = Faces.new(table.unpack(ids))
	end
	return out
end

local FACE_FIELD = { "Front", "Bottom", "Left", "Back", "Top", "Right" }

write[TypeId.Faces] = function(s, values)
	for _, v in values do
		local bits = 0
		for b = 1, 6 do
			if (v :: any)[FACE_FIELD[b]] then
				bits = bit32.bor(bits, bit32.lshift(1, b - 1))
			end
		end
		s:wu8(bits)
	end
end

-- Axes (0x0A) -------------------------------------------------------------
local AXIS_ORDER = { Enum.Axis.X, Enum.Axis.Y, Enum.Axis.Z }
local AXIS_FIELD = { "X", "Y", "Z" }

read[TypeId.Axes] = function(s, count)
	local out = table.create(count)
	for i = 1, count do
		local bits = s:u8()
		local ids = {}
		for b = 0, 2 do
			if bit32.band(bit32.rshift(bits, b), 1) == 1 then
				table.insert(ids, AXIS_ORDER[b + 1])
			end
		end
		out[i] = Axes.new(table.unpack(ids))
	end
	return out
end

write[TypeId.Axes] = function(s, values)
	for _, v in values do
		local bits = 0
		for b = 1, 3 do
			if (v :: any)[AXIS_FIELD[b]] then
				bits = bit32.bor(bits, bit32.lshift(1, b - 1))
			end
		end
		s:wu8(bits)
	end
end

-- BrickColor (0x0B) -------------------------------------------------------
read[TypeId.BrickColor] = function(s, count)
	local nums = Transforms.readInterleavedU32(s, count)
	local out = table.create(count)
	for i = 1, count do
		local ok, value = pcall(BrickColor.new, nums[i])
		out[i] = if ok then value else BrickColor.new(194)
	end
	return out
end

write[TypeId.BrickColor] = function(s, values)
	local nums = table.create(#values)
	for i, v in values do
		nums[i] = (v :: BrickColor).Number
	end
	Transforms.writeInterleavedU32(s, nums)
end

-- Color3 (0x0C) -----------------------------------------------------------
read[TypeId.Color3] = function(s, count)
	local r = Transforms.readInterleavedF32(s, count)
	local g = Transforms.readInterleavedF32(s, count)
	local b = Transforms.readInterleavedF32(s, count)
	local out = table.create(count)
	for i = 1, count do
		out[i] = Color3.new(r[i], g[i], b[i])
	end
	return out
end

write[TypeId.Color3] = function(s, values)
	local n = #values
	local r, g, b = table.create(n), table.create(n), table.create(n)
	for i = 1, n do
		local c = values[i] :: Color3
		r[i], g[i], b[i] = c.R, c.G, c.B
	end
	Transforms.writeInterleavedF32(s, r)
	Transforms.writeInterleavedF32(s, g)
	Transforms.writeInterleavedF32(s, b)
end

-- Vector2 (0x0D) ----------------------------------------------------------
read[TypeId.Vector2] = function(s, count)
	local x = Transforms.readInterleavedF32(s, count)
	local y = Transforms.readInterleavedF32(s, count)
	local out = table.create(count)
	for i = 1, count do
		out[i] = Vector2.new(x[i], y[i])
	end
	return out
end

write[TypeId.Vector2] = function(s, values)
	local n = #values
	local x, y = table.create(n), table.create(n)
	for i = 1, n do
		local v = values[i] :: Vector2
		x[i], y[i] = v.X, v.Y
	end
	Transforms.writeInterleavedF32(s, x)
	Transforms.writeInterleavedF32(s, y)
end

-- Vector3 (0x0E) ----------------------------------------------------------
read[TypeId.Vector3] = function(s, count)
	local x = Transforms.readInterleavedF32(s, count)
	local y = Transforms.readInterleavedF32(s, count)
	local z = Transforms.readInterleavedF32(s, count)
	local out = table.create(count)
	for i = 1, count do
		out[i] = Vector3.new(x[i], y[i], z[i])
	end
	return out
end

write[TypeId.Vector3] = function(s, values)
	local n = #values
	local x, y, z = table.create(n), table.create(n), table.create(n)
	for i = 1, n do
		local v = values[i] :: Vector3
		x[i], y[i], z[i] = v.X, v.Y, v.Z
	end
	Transforms.writeInterleavedF32(s, x)
	Transforms.writeInterleavedF32(s, y)
	Transforms.writeInterleavedF32(s, z)
end

-- CFrame (0x10) -----------------------------------------------------------
-- Rotations come first (id byte + optional raw matrix), then a Vector3 array.
local function readCFrames(s: Stream, count: number): { CFrame }
	local rotations = table.create(count)
	for i = 1, count do
		local id = s:u8()
		if id == 0 then
			local m = table.create(9)
			for k = 1, 9 do
				m[k] = s:f32()
			end
			rotations[i] = m
		else
			local m = ROTATION_MATRIX[id]
			if not m then
				error(`CFrame: unknown special rotation id 0x{string.format("%02x", id)}`)
			end
			rotations[i] = m
		end
	end

	local positions = read[TypeId.Vector3](s, count) :: { Vector3 }

	local out = table.create(count)
	for i = 1, count do
		local p = positions[i]
		local m = rotations[i]
		out[i] = CFrame.new(p.X, p.Y, p.Z, m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9])
	end
	return out
end

local function writeCFrames(s: Stream, values: { CFrame })
	local n = #values
	local positions = table.create(n)
	for i = 1, n do
		local cf = values[i]
		local px, py, pz, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
		positions[i] = Vector3.new(px, py, pz)

		local m = { r00, r01, r02, r10, r11, r12, r20, r21, r22 }
		local id: number? = nil
		if isAxisAligned(m) then
			id = ROTATION_LOOKUP[matrixKey(m)]
		end

		if id then
			s:wu8(id)
		else
			s:wu8(0)
			for k = 1, 9 do
				s:wf32(m[k])
			end
		end
	end
	write[TypeId.Vector3](s, positions :: any)
end

read[TypeId.CFrame] = function(s, count)
	return readCFrames(s, count) :: any
end

write[TypeId.CFrame] = function(s, values)
	writeCFrames(s, values :: any)
end

-- Quaternion (0x11) -------------------------------------------------------
-- Rarely emitted, but present in some older files: 4 f32 + a Vector3 array.
read[TypeId.Quaternion] = function(s, count)
	local quats = table.create(count)
	for i = 1, count do
		quats[i] = { s:f32(), s:f32(), s:f32(), s:f32() }
	end
	local positions = read[TypeId.Vector3](s, count) :: { Vector3 }
	local out = table.create(count)
	for i = 1, count do
		local q = quats[i]
		local p = positions[i]
		out[i] = CFrame.new(p.X, p.Y, p.Z, q[1], q[2], q[3], q[4])
	end
	return out
end

write[TypeId.Quaternion] = function(s, values)
	local n = #values
	local positions = table.create(n)
	for i = 1, n do
		local cf = values[i] :: CFrame
		local axis, angle = cf:ToAxisAngle()
		local half = angle / 2
		local sn = math.sin(half)
		s:wf32(axis.X * sn)
		s:wf32(axis.Y * sn)
		s:wf32(axis.Z * sn)
		s:wf32(math.cos(half))
		positions[i] = cf.Position
	end
	write[TypeId.Vector3](s, positions :: any)
end

-- Enum (0x12) -------------------------------------------------------------
read[TypeId.Enum] = function(s, count)
	return Transforms.readInterleavedU32(s, count)
end

write[TypeId.Enum] = function(s, values)
	Transforms.writeInterleavedU32(s, values :: any)
end

-- Referent (0x13) ---------------------------------------------------------
-- Stored as transformed i32s, accumulated: each value is a delta.
read[TypeId.Referent] = function(s, count)
	local raw = Transforms.readInterleavedI32(s, count)
	local out = table.create(count)
	local acc = 0
	for i = 1, count do
		acc += raw[i]
		out[i] = acc
	end
	return out
end

write[TypeId.Referent] = function(s, values)
	local n = #values
	local deltas = table.create(n)
	local prev = 0
	for i = 1, n do
		local v = values[i] :: number
		deltas[i] = v - prev
		prev = v
	end
	Transforms.writeInterleavedI32(s, deltas)
end

-- Vector3int16 (0x14) -----------------------------------------------------
read[TypeId.Vector3int16] = function(s, count)
	local out = table.create(count)
	for i = 1, count do
		out[i] = Vector3int16.new(s:i16(), s:i16(), s:i16())
	end
	return out
end

write[TypeId.Vector3int16] = function(s, values)
	for _, v in values do
		local vv = v :: Vector3int16
		s:wi16(vv.X)
		s:wi16(vv.Y)
		s:wi16(vv.Z)
	end
end

-- NumberSequence (0x15) ---------------------------------------------------
read[TypeId.NumberSequence] = function(s, count)
	local out = table.create(count)
	for i = 1, count do
		local kpCount = s:u32()
		local keypoints = table.create(kpCount)
		for k = 1, kpCount do
			local t, v, e = s:f32(), s:f32(), s:f32()
			keypoints[k] = NumberSequenceKeypoint.new(t, v, e)
		end
		if kpCount < 2 then
			-- NumberSequence requires at least two keypoints
			local v = if kpCount == 1 then keypoints[1].Value else 0
			out[i] = NumberSequence.new(v)
		else
			out[i] = NumberSequence.new(keypoints)
		end
	end
	return out
end

write[TypeId.NumberSequence] = function(s, values)
	for _, v in values do
		local seq = v :: NumberSequence
		local kps = seq.Keypoints
		s:wu32(#kps)
		for _, kp in kps do
			s:wf32(kp.Time)
			s:wf32(kp.Value)
			s:wf32(kp.Envelope)
		end
	end
end

-- ColorSequence (0x16) ----------------------------------------------------
read[TypeId.ColorSequence] = function(s, count)
	local out = table.create(count)
	for i = 1, count do
		local kpCount = s:u32()
		local keypoints = table.create(kpCount)
		for k = 1, kpCount do
			local t = s:f32()
			local r, g, b = s:f32(), s:f32(), s:f32()
			s:f32() -- envelope, serialized but unused
			keypoints[k] = ColorSequenceKeypoint.new(t, Color3.new(r, g, b))
		end
		if kpCount < 2 then
			local c = if kpCount == 1 then keypoints[1].Value else Color3.new()
			out[i] = ColorSequence.new(c)
		else
			out[i] = ColorSequence.new(keypoints)
		end
	end
	return out
end

write[TypeId.ColorSequence] = function(s, values)
	for _, v in values do
		local seq = v :: ColorSequence
		local kps = seq.Keypoints
		s:wu32(#kps)
		for _, kp in kps do
			s:wf32(kp.Time)
			s:wf32(kp.Value.R)
			s:wf32(kp.Value.G)
			s:wf32(kp.Value.B)
			s:wf32(0)
		end
	end
end

-- NumberRange (0x17) ------------------------------------------------------
read[TypeId.NumberRange] = function(s, count)
	local out = table.create(count)
	for i = 1, count do
		out[i] = NumberRange.new(s:f32(), s:f32())
	end
	return out
end

write[TypeId.NumberRange] = function(s, values)
	for _, v in values do
		local r = v :: NumberRange
		s:wf32(r.Min)
		s:wf32(r.Max)
	end
end

-- Rect (0x18) -------------------------------------------------------------
read[TypeId.Rect] = function(s, count)
	local minX = Transforms.readInterleavedF32(s, count)
	local minY = Transforms.readInterleavedF32(s, count)
	local maxX = Transforms.readInterleavedF32(s, count)
	local maxY = Transforms.readInterleavedF32(s, count)
	local out = table.create(count)
	for i = 1, count do
		out[i] = Rect.new(minX[i], minY[i], maxX[i], maxY[i])
	end
	return out
end

write[TypeId.Rect] = function(s, values)
	local n = #values
	local a, b, c, d = table.create(n), table.create(n), table.create(n), table.create(n)
	for i = 1, n do
		local r = values[i] :: Rect
		a[i], b[i] = r.Min.X, r.Min.Y
		c[i], d[i] = r.Max.X, r.Max.Y
	end
	Transforms.writeInterleavedF32(s, a)
	Transforms.writeInterleavedF32(s, b)
	Transforms.writeInterleavedF32(s, c)
	Transforms.writeInterleavedF32(s, d)
end

-- PhysicalProperties (0x19) -----------------------------------------------
read[TypeId.PhysicalProperties] = function(s, count)
	local out = table.create(count)
	for i = 1, count do
		local flags = s:u8()
		local custom = bit32.band(flags, 1) == 1
		local hasAcoustic = bit32.band(flags, 2) == 2

		if not custom and not hasAcoustic then
			out[i] = false -- sentinel for "default/nil"
			continue
		end

		-- Kept as a table rather than a PhysicalProperties value, because the
		-- Roblox type has no room for AcousticAbsorption or for the
		-- "acoustic flag set but not custom" case. applyValue turns this into
		-- a real PhysicalProperties when it reaches an Instance.
		local entry: any = {
			__kind = "PhysicalProperties",
			custom = custom,
			hasAcoustic = hasAcoustic,
		}
		if custom then
			entry.density = s:f32()
			entry.friction = s:f32()
			entry.elasticity = s:f32()
			entry.frictionWeight = s:f32()
			entry.elasticityWeight = s:f32()
			entry.acousticAbsorption = if hasAcoustic then s:f32() else 1
		end
		out[i] = entry
	end
	return out
end

write[TypeId.PhysicalProperties] = function(s, values)
	for _, v in values do
		if v == nil or v == false then
			s:wu8(0)
		elseif type(v) == "table" then
			-- straight from a DOM: preserves the flag bits exactly
			local flags = 0
			if v.custom then
				flags = bit32.bor(flags, 1)
			end
			if v.hasAcoustic then
				flags = bit32.bor(flags, 2)
			end
			s:wu8(flags)
			if v.custom then
				s:wf32(v.density)
				s:wf32(v.friction)
				s:wf32(v.elasticity)
				s:wf32(v.frictionWeight)
				s:wf32(v.elasticityWeight)
				if v.hasAcoustic then
					s:wf32(v.acousticAbsorption or 1)
				end
			end
		else
			local pp = v :: PhysicalProperties
			s:wu8(1)
			s:wf32(pp.Density)
			s:wf32(pp.Friction)
			s:wf32(pp.Elasticity)
			s:wf32(pp.FrictionWeight)
			s:wf32(pp.ElasticityWeight)
		end
	end
end

-- Color3uint8 (0x1A) ------------------------------------------------------
read[TypeId.Color3uint8] = function(s, count)
	local r = table.create(count)
	local g = table.create(count)
	local b = table.create(count)
	for i = 1, count do
		r[i] = s:u8()
	end
	for i = 1, count do
		g[i] = s:u8()
	end
	for i = 1, count do
		b[i] = s:u8()
	end
	local out = table.create(count)
	for i = 1, count do
		out[i] = Color3.fromRGB(r[i], g[i], b[i])
	end
	return out
end

write[TypeId.Color3uint8] = function(s, values)
	local n = #values
	for i = 1, n do
		s:wu8(math.round((values[i] :: Color3).R * 255))
	end
	for i = 1, n do
		s:wu8(math.round((values[i] :: Color3).G * 255))
	end
	for i = 1, n do
		s:wu8(math.round((values[i] :: Color3).B * 255))
	end
end

-- Int64 (0x1B) ------------------------------------------------------------
read[TypeId.Int64] = function(s, count)
	return Transforms.readInterleavedI64(s, count)
end

write[TypeId.Int64] = function(s, values)
	Transforms.writeInterleavedI64(s, values :: any)
end

-- SharedString (0x1C) -----------------------------------------------------
-- Values are 0-based indices into the SSTR table; we return them 1-based.
read[TypeId.SharedString] = function(s, count)
	local raw = Transforms.readInterleavedU32(s, count)
	for i = 1, count do
		raw[i] += 1
	end
	return raw
end

write[TypeId.SharedString] = function(s, values)
	local out = table.create(#values)
	for i, v in values do
		out[i] = (v :: number) - 1
	end
	Transforms.writeInterleavedU32(s, out)
end

-- OptionalCFrame (0x1E) ---------------------------------------------------
read[TypeId.OptionalCFrame] = function(s, count)
	local cfType = s:u8()
	if cfType ~= TypeId.CFrame then
		error(`OptionalCFrame: expected inner CFrame type id, got 0x{string.format("%02x", cfType)}`)
	end
	local frames = readCFrames(s, count)

	local boolType = s:u8()
	if boolType ~= TypeId.Bool then
		error(`OptionalCFrame: expected inner Bool type id, got 0x{string.format("%02x", boolType)}`)
	end
	local out = table.create(count)
	for i = 1, count do
		local present = s:u8() ~= 0
		out[i] = if present then frames[i] else false
	end
	return out
end

write[TypeId.OptionalCFrame] = function(s, values)
	local n = #values
	s:wu8(TypeId.CFrame)
	local frames = table.create(n)
	for i = 1, n do
		local v = values[i]
		frames[i] = if v == nil or v == false then CFrame.identity else v
	end
	writeCFrames(s, frames :: any)

	s:wu8(TypeId.Bool)
	for i = 1, n do
		local v = values[i]
		s:wu8(if v == nil or v == false then 0 else 1)
	end
end

-- UniqueId (0x1F) ---------------------------------------------------------
-- 16-byte records, byte interleaved. Kept opaque so they round-trip exactly.
read[TypeId.UniqueId] = function(s, count)
	local raw = Transforms.readInterleaved(s, count, 16)
	local out = table.create(count)
	for i = 1, count do
		local rec = buffer.create(16)
		buffer.copy(rec, 0, raw, (i - 1) * 16, 16)
		out[i] = rec
	end
	return out
end

write[TypeId.UniqueId] = function(s, values)
	local n = #values
	local raw = buffer.create(n * 16)
	for i = 1, n do
		local v = values[i]
		if typeof(v) == "buffer" and buffer.len(v :: buffer) == 16 then
			buffer.copy(raw, (i - 1) * 16, v :: buffer, 0, 16)
		end
		-- otherwise leave zeroed; Studio regenerates UniqueIds on load
	end
	Transforms.writeInterleaved(s, raw, n, 16)
end

-- Font (0x20) -------------------------------------------------------------
read[TypeId.Font] = function(s, count)
	local out = table.create(count)
	for i = 1, count do
		local familyLen = s:u32()
		local family = if familyLen > 0 then s:str(familyLen) else ""
		local weight = s:u16()
		local style = s:u8()
		local cachedLen = s:u32()
		local cachedFaceId = if cachedLen > 0 then s:str(cachedLen) else ""

		-- Kept as a table: the Roblox Font type cannot carry CachedFaceId,
		-- and dropping it would make round-trips lossy. applyValue builds a
		-- real Font from this when assigning to an Instance.
		out[i] = {
			__kind = "Font",
			family = family,
			weight = weight,
			style = style,
			cachedFaceId = cachedFaceId,
		} :: any
	end
	return out
end

write[TypeId.Font] = function(s, values)
	for _, v in values do
		if type(v) == "table" then
			s:wu32(#v.family)
			s:wstr(v.family)
			s:wu16(v.weight)
			s:wu8(v.style)
			s:wu32(#v.cachedFaceId)
			s:wstr(v.cachedFaceId)
		else
			local f = v :: Font
			s:wu32(#f.Family)
			s:wstr(f.Family)
			s:wu16(f.Weight.Value)
			s:wu8(if f.Style == Enum.FontStyle.Italic then 1 else 0)
			s:wu32(0) -- CachedFaceId, allowed to be empty
		end
	end
end

-- SecurityCapabilities (0x21) ---------------------------------------------
-- A 64-bit bitfield, stored interleaved. Kept as a number pair for fidelity.
read[TypeId.SecurityCapabilities] = function(s, count)
	local raw = Transforms.readInterleaved(s, count, 8)
	local out = table.create(count)
	for i = 1, count do
		local p = (i - 1) * 8
		local lo = buffer.readu32(raw, p)
		local hi = buffer.readu32(raw, p + 4)
		out[i] = hi * 4294967296 + lo
	end
	return out
end

write[TypeId.SecurityCapabilities] = function(s, values)
	local n = #values
	local raw = buffer.create(n * 8)
	for i = 1, n do
		local v = (values[i] :: number) or 0
		buffer.writeu32(raw, (i - 1) * 8, v % 4294967296)
		buffer.writeu32(raw, (i - 1) * 8 + 4, math.floor(v / 4294967296) % 4294967296)
	end
	Transforms.writeInterleaved(s, raw, n, 8)
end

-- Content (0x22) ----------------------------------------------------------
-- Represented as { sourceType = 0|1|2, uri = string?, ref = number? }
read[TypeId.Content] = function(s, count)
	local sourceTypes = Transforms.readInterleavedU32(s, count)

	local uriCount = s:u32()
	local uris = table.create(uriCount)
	for i = 1, uriCount do
		local len = s:u32()
		uris[i] = if len > 0 then s:str(len) else ""
	end

	local objectCount = s:u32()
	local objectRefs = read[TypeId.Referent](s, objectCount) :: { number }

	local externalCount = s:u32()
	local externalRefs = read[TypeId.Referent](s, externalCount) :: { number }
	local _ = externalRefs

	local out = table.create(count)
	local uriCursor, objCursor = 1, 1
	for i = 1, count do
		local st = sourceTypes[i]
		if st == 1 then
			out[i] = { sourceType = 1, uri = uris[uriCursor] }
			uriCursor += 1
		elseif st == 2 then
			out[i] = { sourceType = 2, ref = objectRefs[objCursor] }
			objCursor += 1
		else
			out[i] = { sourceType = 0 }
		end
	end
	return out
end

write[TypeId.Content] = function(s, values)
	local n = #values
	local sourceTypes = table.create(n)
	local uris: { string } = {}
	local refs: { number } = {}

	for i = 1, n do
		local v = values[i] :: any
		local st = if type(v) == "table" then v.sourceType or 0 else 0
		sourceTypes[i] = st
		if st == 1 then
			table.insert(uris, v.uri or "")
		elseif st == 2 then
			table.insert(refs, v.ref or -1)
		end
	end

	Transforms.writeInterleavedU32(s, sourceTypes)

	s:wu32(#uris)
	for _, uri in uris do
		s:wu32(#uri)
		s:wstr(uri)
	end

	s:wu32(#refs)
	write[TypeId.Referent](s, refs :: any)

	s:wu32(0) -- external object refs are never applicable to files we write
	write[TypeId.Referent](s, {})
end

return DataTypes
