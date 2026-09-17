--!strict
--[[
	Encoder.luau

	Walks a set of Instances and writes the binary model format back out.

	Chunk order matches what Studio produces: META, SSTR, one INST per class,
	the PROP chunks for that class, then PRNT and END. PRNT entries are
	written in depth-first post-order, which is the order Studio applies them.
]]

local Stream = require(script.Parent.Stream)
local DataTypes = require(script.Parent.DataTypes)
local Reflection = require(script.Parent.Reflection)
local Attributes = require(script.Parent.Attributes)
local LZ4 = require(script.Parent.LZ4)
local MD5 = require(script.Parent.MD5)

type Stream = Stream.Stream

local TypeId = DataTypes.TypeId
local CollectionService = game:GetService("CollectionService")

local MAGIC = "<roblox!"
local SIGNATURE = "\x89\xff\x0d\x0a\x1a\x0a"

export type EncodeOptions = {
	compression: ("lz4" | "none")?,
	compressionLevel: number?,
	metadata: { [string]: string }?,
	includeAttributes: boolean?,
	includeTags: boolean?,
	onWarning: ((string) -> ())?,
}

local Encoder = {}

-- --------------------------------------------------------------- collection

local function collect(roots: { Instance }): ({ Instance }, { [Instance]: number })
	local flat: { Instance } = {}
	local referents: { [Instance]: number } = {}

	local function visit(inst: Instance)
		referents[inst] = #flat
		table.insert(flat, inst)
		for _, child in inst:GetChildren() do
			visit(child)
		end
	end

	for _, root in roots do
		visit(root)
	end
	return flat, referents
end

-- Depth-first post-order: every descendant is listed before its ancestor.
local function parentOrder(roots: { Instance }, referents: { [Instance]: number }): ({ number }, { number })
	local children: { number } = {}
	local parents: { number } = {}

	local rootSet: { [Instance]: boolean } = {}
	for _, r in roots do
		rootSet[r] = true
	end

	local function visit(inst: Instance)
		for _, child in inst:GetChildren() do
			visit(child)
		end
		table.insert(children, referents[inst])
		local parent = inst.Parent
		if parent and referents[parent] and not rootSet[inst] then
			table.insert(parents, referents[parent])
		else
			table.insert(parents, -1)
		end
	end

	for _, root in roots do
		visit(root)
	end
	return children, parents
end

-- ------------------------------------------------------------ value reading

type Ctx = {
	referents: { [Instance]: number },
	sharedStrings: { string },
	sharedIndex: { [string]: number },
	includeAttributes: boolean,
	includeTags: boolean,
	warn: (string) -> (),
}

local function defaultFor(typeId: number): any
	if typeId == TypeId.String or typeId == TypeId.Bytecode then
		return ""
	elseif typeId == TypeId.Bool then
		return false
	elseif typeId == TypeId.Int32 or typeId == TypeId.Int64 or typeId == TypeId.Enum then
		return 0
	elseif typeId == TypeId.Float32 or typeId == TypeId.Float64 then
		return 0
	elseif typeId == TypeId.SecurityCapabilities then
		return 0
	elseif typeId == TypeId.Referent then
		return -1
	elseif typeId == TypeId.UDim then
		return UDim.new(0, 0)
	elseif typeId == TypeId.UDim2 then
		return UDim2.new()
	elseif typeId == TypeId.Ray then
		return Ray.new(Vector3.zero, Vector3.zero)
	elseif typeId == TypeId.Faces then
		return Faces.new()
	elseif typeId == TypeId.Axes then
		return Axes.new()
	elseif typeId == TypeId.BrickColor then
		return BrickColor.new(194)
	elseif typeId == TypeId.Color3 or typeId == TypeId.Color3uint8 then
		return Color3.new()
	elseif typeId == TypeId.Vector2 then
		return Vector2.zero
	elseif typeId == TypeId.Vector3 then
		return Vector3.zero
	elseif typeId == TypeId.Vector3int16 then
		return Vector3int16.new()
	elseif typeId == TypeId.CFrame then
		return CFrame.identity
	elseif typeId == TypeId.OptionalCFrame or typeId == TypeId.PhysicalProperties then
		return false
	elseif typeId == TypeId.NumberSequence then
		return NumberSequence.new(0)
	elseif typeId == TypeId.ColorSequence then
		return ColorSequence.new(Color3.new())
	elseif typeId == TypeId.NumberRange then
		return NumberRange.new(0)
	elseif typeId == TypeId.Rect then
		return Rect.new(0, 0, 0, 0)
	elseif typeId == TypeId.Font then
		return Font.fromEnum(Enum.Font.SourceSans)
	elseif typeId == TypeId.UniqueId then
		return buffer.create(16)
	elseif typeId == TypeId.SharedString then
		return 1
	elseif typeId == TypeId.Content then
		return { sourceType = 0 }
	end
	return nil
end

local function internShared(ctx: Ctx, value: string): number
	local existing = ctx.sharedIndex[value]
	if existing then
		return existing
	end
	table.insert(ctx.sharedStrings, value)
	local idx = #ctx.sharedStrings
	ctx.sharedIndex[value] = idx
	return idx
end

local function readValue(instance: Instance, descriptor: Reflection.Descriptor, ctx: Ctx): any
	local serialized = descriptor.serialized
	local typeId = descriptor.typeId

	if serialized == "AttributesSerialize" then
		if not ctx.includeAttributes then
			return ""
		end
		local ok, attrs = pcall(function()
			return instance:GetAttributes()
		end)
		if not ok then
			return ""
		end
		local okBlob, blob = pcall(Attributes.encode, attrs)
		if not okBlob then
			ctx.warn(`could not encode attributes on {instance:GetFullName()}: {blob}`)
			return ""
		end
		return blob
	end

	if serialized == "Tags" then
		if not ctx.includeTags then
			return ""
		end
		local ok, tags = pcall(function()
			return CollectionService:GetTags(instance)
		end)
		if not ok or #tags == 0 then
			return ""
		end
		return table.concat(tags, "\0")
	end

	if serialized == "WorldPivotData" then
		if instance:IsA("Model") then
			local ok, pivot = pcall(function()
				return instance:GetPivot()
			end)
			return if ok then pivot else false
		end
		return false
	end

	local ok, value = pcall(function()
		return (instance :: any)[descriptor.name]
	end)
	if not ok or value == nil then
		return defaultFor(typeId)
	end

	local vt = typeof(value)

	if typeId == TypeId.Enum then
		return if vt == "EnumItem" then value.Value else (tonumber(value) or 0)
	elseif typeId == TypeId.Referent then
		if vt == "Instance" then
			local ref = ctx.referents[value]
			return if ref ~= nil then ref else -1
		end
		return -1
	elseif typeId == TypeId.SharedString then
		if vt == "string" then
			return internShared(ctx, value)
		end
		return defaultFor(typeId)
	elseif typeId == TypeId.PhysicalProperties then
		return if vt == "PhysicalProperties" then value else false
	elseif typeId == TypeId.OptionalCFrame then
		return if vt == "CFrame" then value else false
	elseif typeId == TypeId.Color3uint8 or typeId == TypeId.Color3 then
		return if vt == "Color3" then value else Color3.new()
	elseif typeId == TypeId.Content then
		if vt == "Content" then
			local uri = (value :: any).Uri
			if uri then
				return { sourceType = 1, uri = uri }
			end
			return { sourceType = 0 }
		elseif vt == "string" then
			return { sourceType = if #value > 0 then 1 else 0, uri = value }
		end
		return { sourceType = 0 }
	elseif typeId == TypeId.String or typeId == TypeId.Bytecode then
		if vt == "string" then
			return value
		elseif vt == "Content" then
			return tostring((value :: any).Uri or "")
		end
		return tostring(value)
	elseif typeId == TypeId.Int32 or typeId == TypeId.Int64 then
		return math.round(tonumber(value) or 0)
	elseif typeId == TypeId.Float32 or typeId == TypeId.Float64 then
		return tonumber(value) or 0
	end

	return value
end

-- ------------------------------------------------------------ chunk writing

local function writeChunk(out: Stream, name: string, body: Stream, compress: boolean, level: number?)
	local raw = body:finish()
	local rawLen = buffer.len(raw)

	local payload: buffer? = nil
	if compress and rawLen > 0 then
		local ok, compressed = pcall(LZ4.compress, raw, level)
		if ok and buffer.len(compressed) < rawLen then
			payload = compressed
		end
	end

	local padded = name .. string.rep("\0", 4 - #name)
	out:wstr(padded)
	out:wu32(if payload then buffer.len(payload) else 0)
	out:wu32(rawLen)
	out:wzeros(4)
	if payload then
		out:wbuf(payload)
	else
		out:wbuf(raw)
	end
end

local function writeBinaryString(s: Stream, str: string)
	s:wu32(#str)
	s:wstr(str)
end

-- ------------------------------------------------------------------ encode

function Encoder.encode(roots: { Instance }, options: EncodeOptions?): buffer
	local opts = options or {}
	local warn_ = opts.onWarning or function(msg: string)
		warn(`[RbxmSerializer] {msg}`)
	end
	local compress = (opts.compression or "lz4") == "lz4"
	local level = opts.compressionLevel

	local flat, referents = collect(roots)

	local ctx: Ctx = {
		referents = referents,
		sharedStrings = {},
		sharedIndex = {},
		includeAttributes = opts.includeAttributes ~= false,
		includeTags = opts.includeTags ~= false,
		warn = warn_,
	}

	-- group by class, preserving first-seen order
	local classOrder: { string } = {}
	local byClass: { [string]: { Instance } } = {}
	for _, inst in flat do
		local cn = inst.ClassName
		local bucket = byClass[cn]
		if not bucket then
			bucket = {}
			byClass[cn] = bucket
			table.insert(classOrder, cn)
		end
		table.insert(bucket, inst)
	end

	-- Build every PROP chunk body first, because SharedStrings discovered here
	-- have to land in the SSTR chunk, which is written earlier in the file.
	type PendingProp = { classId: number, name: string, typeId: number, body: Stream }
	local instChunks: { { classId: number, body: Stream } } = {}
	local propChunks: { PendingProp } = {}

	for classId, className in classOrder do
		local instances = byClass[className]
		local zeroBasedId = classId - 1

		-- INST
		local instBody = Stream.new(64)
		instBody:wu32(zeroBasedId)
		writeBinaryString(instBody, className)
		local isService = Reflection.isService(className)
		instBody:wu8(if isService then 1 else 0)
		instBody:wu32(#instances)

		local refs = table.create(#instances)
		for i, inst in instances do
			refs[i] = referents[inst]
		end
		DataTypes.write[TypeId.Referent](instBody, refs :: any)

		if isService then
			for _ = 1, #instances do
				instBody:wu8(1)
			end
		end
		table.insert(instChunks, { classId = zeroBasedId, body = instBody })

		-- PROP, one per descriptor
		local descriptors = Reflection.descriptorsFor(instances[1])
		for _, descriptor in descriptors do
			local values = table.create(#instances)
			local usable = true

			for i, inst in instances do
				local v = readValue(inst, descriptor, ctx)
				if v == nil then
					usable = false
					break
				end
				values[i] = v
			end

			if not usable then
				continue
			end

			local writer = DataTypes.write[descriptor.typeId]
			if not writer then
				warn_(`no writer for type id 0x{string.format("%02x", descriptor.typeId)}; skipping {descriptor.serialized}`)
				continue
			end

			local body = Stream.new(64)
			body:wu32(zeroBasedId)
			writeBinaryString(body, descriptor.serialized)
			body:wu8(descriptor.typeId)

			local ok, err = pcall(writer, body, values)
			if not ok then
				warn_(`failed to write "{className}.{descriptor.serialized}": {err}`)
				continue
			end

			table.insert(propChunks, {
				classId = zeroBasedId,
				name = descriptor.serialized,
				typeId = descriptor.typeId,
				body = body,
			})
		end
	end

	-- ------------------------------------------------------------ assemble

	local out = Stream.new(4096)
	out:wstr(MAGIC)
	out:wstr(SIGNATURE)
	out:wu16(0)
	out:wi32(#classOrder)
	out:wi32(#flat)
	out:wzeros(8)

	-- META
	local metadata = opts.metadata or { ExplicitAutoJoints = "true" }
	local metaCount = 0
	for _ in metadata do
		metaCount += 1
	end
	if metaCount > 0 then
		local body = Stream.new(64)
		body:wu32(metaCount)
		for key, value in metadata do
			writeBinaryString(body, key)
			writeBinaryString(body, value)
		end
		writeChunk(out, "META", body, compress, level)
	end

	-- SSTR
	if #ctx.sharedStrings > 0 then
		local body = Stream.new(256)
		body:wu32(0) -- version
		body:wu32(#ctx.sharedStrings)
		for _, str in ctx.sharedStrings do
			body:wstr(MD5.digest(str))
			writeBinaryString(body, str)
		end
		writeChunk(out, "SSTR", body, compress, level)
	end

	-- INST chunks, then all PROP chunks for that class
	for _, inst in instChunks do
		writeChunk(out, "INST", inst.body, compress, level)
		for _, prop in propChunks do
			if prop.classId == inst.classId then
				writeChunk(out, "PROP", prop.body, compress, level)
			end
		end
	end

	-- PRNT
	do
		local childRefs, parentRefs = parentOrder(roots, referents)
		local body = Stream.new(64)
		body:wu8(0)
		body:wu32(#childRefs)
		DataTypes.write[TypeId.Referent](body, childRefs :: any)
		DataTypes.write[TypeId.Referent](body, parentRefs :: any)
		writeChunk(out, "PRNT", body, compress, level)
	end

	-- END (never compressed)
	do
		local body = Stream.new(16)
		body:wstr("</roblox>")
		writeChunk(out, "END\0", body, false, nil)
	end

	return out:finish()
end

-- ------------------------------------------------------------- DOM encode

--[[
	Writes a DOM straight back to bytes.

	This is the pass-through path: nothing goes near the Instance API and
	nothing is looked up in the reflection database, because a decoded DOM
	already carries every property name and type id the file declared. Read a
	file, edit whatever you want, write it back, and everything you didn't
	touch survives byte-for-byte — including properties this module has never
	heard of and ones Studio won't let you set from Luau (UniqueId, Tags,
	AttributesSerialize, MeshData, and so on).

	Referents are renumbered densely in pre-order, and Referent-typed property
	values are remapped to match, so a hand-edited DOM stays consistent.
]]
function Encoder.encodeDom(dom: any, options: EncodeOptions?): buffer
	local opts = options or {}
	local warn_ = opts.onWarning or function(msg: string)
		warn(`[RbxmSerializer] {msg}`)
	end
	local compress = (opts.compression or "lz4") == "lz4"
	local level = opts.compressionLevel

	-- flatten pre-order
	local flat: { any } = {}
	local newRef: { [number]: number } = {}
	local function visit(node: any)
		newRef[node.referent] = #flat
		table.insert(flat, node)
		for _, child in node.children do
			visit(child)
		end
	end

	local roots = dom.roots
	if not roots or #roots == 0 then
		roots = {}
		for _, ref in dom.order do
			local node = dom.instances[ref]
			if node and node.parentReferent == -1 then
				table.insert(roots, node)
			end
		end
	end
	for _, root in roots do
		visit(root)
	end

	local ctx: Ctx = {
		referents = {} :: any,
		sharedStrings = {},
		sharedIndex = {},
		includeAttributes = true,
		includeTags = true,
		warn = warn_,
	}

	-- group by class, first-seen order
	local classOrder: { string } = {}
	local byClass: { [string]: { any } } = {}
	for _, node in flat do
		local bucket = byClass[node.className]
		if not bucket then
			bucket = {}
			byClass[node.className] = bucket
			table.insert(classOrder, node.className)
		end
		table.insert(bucket, node)
	end

	-- declared property order, keyed by class name
	local declaredOrder: { [string]: { string } } = {}
	for _, class in dom.classes or {} do
		declaredOrder[class.className] = class.propertyOrder
	end

	type PendingProp = { classId: number, body: Stream }
	local instChunks: { { classId: number, body: Stream } } = {}
	local propChunks: { PendingProp } = {}

	for classId, className in classOrder do
		local nodes = byClass[className]
		local zeroBasedId = classId - 1
		local isService = nodes[1].isService == true

		local instBody = Stream.new(64)
		instBody:wu32(zeroBasedId)
		writeBinaryString(instBody, className)
		instBody:wu8(if isService then 1 else 0)
		instBody:wu32(#nodes)

		local refs = table.create(#nodes)
		for i, node in nodes do
			refs[i] = newRef[node.referent]
		end
		DataTypes.write[TypeId.Referent](instBody, refs :: any)

		if isService then
			for _ = 1, #nodes do
				instBody:wu8(1)
			end
		end
		table.insert(instChunks, { classId = zeroBasedId, body = instBody })

		-- property set: declared order first, then anything added by hand
		local order: { string } = {}
		local seen: { [string]: boolean } = {}
		for _, name in declaredOrder[className] or {} do
			if not seen[name] then
				seen[name] = true
				table.insert(order, name)
			end
		end
		local extras: { string } = {}
		for _, node in nodes do
			for name in node.properties do
				if not seen[name] and string.sub(name, 1, 1) ~= "\0" then
					seen[name] = true
					table.insert(extras, name)
				end
			end
		end
		table.sort(extras)
		table.move(extras, 1, #extras, #order + 1, order)

		for _, name in order do
			local typeId: number? = nil
			for _, node in nodes do
				typeId = node.propertyTypes and node.propertyTypes[name]
				if typeId then
					break
				end
			end
			if not typeId then
				warn_(`no type id recorded for "{className}.{name}"; skipping`)
				continue
			end

			local writer = DataTypes.write[typeId]
			if not writer then
				warn_(`no writer for type id 0x{string.format("%02x", typeId)}; skipping {name}`)
				continue
			end

			local values = table.create(#nodes)
			for i, node in nodes do
				local v = node.properties[name]
				if v == nil and typeId ~= TypeId.OptionalCFrame then
					v = defaultFor(typeId)
				end

				if typeId == TypeId.Referent then
					v = if type(v) == "number" then (newRef[v] or -1) else -1
				elseif typeId == TypeId.SharedString then
					v = internShared(ctx, if type(v) == "string" then v else "")
				elseif typeId == TypeId.Content and type(v) == "table" and v.ref ~= nil then
					v = { sourceType = v.sourceType, uri = v.uri, ref = newRef[v.ref] or -1 }
				end

				values[i] = v
			end

			local body = Stream.new(64)
			body:wu32(zeroBasedId)
			writeBinaryString(body, name)
			body:wu8(typeId)

			local ok, err = pcall(writer, body, values)
			if not ok then
				warn_(`failed to write "{className}.{name}": {err}`)
				continue
			end

			table.insert(propChunks, { classId = zeroBasedId, body = body })
		end
	end

	-- ------------------------------------------------------------ assemble

	local out = Stream.new(4096)
	out:wstr(MAGIC)
	out:wstr(SIGNATURE)
	out:wu16(0)
	out:wi32(#classOrder)
	out:wi32(#flat)
	out:wzeros(8)

	local metadata = opts.metadata or dom.metadata or {}
	local metaCount = 0
	for _ in metadata do
		metaCount += 1
	end
	if metaCount > 0 then
		local body = Stream.new(64)
		body:wu32(metaCount)
		for key, value in metadata do
			writeBinaryString(body, key)
			writeBinaryString(body, value)
		end
		writeChunk(out, "META", body, compress, level)
	end

	if #ctx.sharedStrings > 0 then
		local body = Stream.new(256)
		body:wu32(0)
		body:wu32(#ctx.sharedStrings)
		for _, str in ctx.sharedStrings do
			body:wstr(MD5.digest(str))
			writeBinaryString(body, str)
		end
		writeChunk(out, "SSTR", body, compress, level)
	end

	for _, inst in instChunks do
		writeChunk(out, "INST", inst.body, compress, level)
		for _, prop in propChunks do
			if prop.classId == inst.classId then
				writeChunk(out, "PROP", prop.body, compress, level)
			end
		end
	end

	-- PRNT, depth-first post-order
	do
		local children: { number } = {}
		local parents: { number } = {}
		local function post(node: any, parentRef: number)
			for _, child in node.children do
				post(child, newRef[node.referent])
			end
			table.insert(children, newRef[node.referent])
			table.insert(parents, parentRef)
		end
		for _, root in roots do
			post(root, -1)
		end

		local body = Stream.new(64)
		body:wu8(0)
		body:wu32(#children)
		DataTypes.write[TypeId.Referent](body, children :: any)
		DataTypes.write[TypeId.Referent](body, parents :: any)
		writeChunk(out, "PRNT", body, compress, level)
	end

	do
		local body = Stream.new(16)
		body:wstr("</roblox>")
		writeChunk(out, "END\0", body, false, nil)
	end

	return out:finish()
end

return Encoder
