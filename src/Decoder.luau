--!strict
--[[
	Decoder.luau

	Reads the binary model format into a DOM, then (optionally) instantiates
	that DOM as live Instances.

	    local dom = Decoder.decodeDom(bytes)
	    local roots = Decoder.decode(bytes)
]]

local Stream = require(script.Parent.Stream)
local DataTypes = require(script.Parent.DataTypes)
local Reflection = require(script.Parent.Reflection)
local Attributes = require(script.Parent.Attributes)
local LZ4 = require(script.Parent.LZ4)
local ZSTD = require(script.Parent.ZSTD)

type Stream = Stream.Stream

local TypeId = DataTypes.TypeId

local MAGIC = "<roblox!"
local SIGNATURE = "\x89\xff\x0d\x0a\x1a\x0a"

export type DomInstance = {
	referent: number,
	className: string,
	isService: boolean,
	properties: { [string]: any }, -- keyed by *serialized* name
	-- Serialized name -> type id, shared with every instance of the class.
	-- This is what makes a DOM re-encodable without any reflection data.
	propertyTypes: { [string]: number },
	children: { DomInstance },
	parentReferent: number,
}

export type DomClass = {
	classId: number,
	className: string,
	isService: boolean,
	referents: { number },
	-- Property names in the order their PROP chunks appeared.
	propertyOrder: { string },
	propertyTypes: { [string]: number },
}

export type Dom = {
	metadata: { [string]: string },
	sharedStrings: { string },
	instances: { [number]: DomInstance },
	classes: { DomClass },
	roots: { DomInstance },
	order: { number },
}

export type DecodeOptions = {
	applyAttributes: boolean?,
	applyTags: boolean?,
	onWarning: ((string) -> ())?,
}

local Decoder = {}

local CollectionService = game:GetService("CollectionService")

-- ------------------------------------------------------------ chunk layer

type Chunk = {
	name: string,
	data: Stream,
}

local function readChunk(s: Stream, warn_: (string) -> ()): Chunk?
	if s:remaining() < 16 then
		return nil
	end

	local rawName = s:str(4)
	local name = (string.gsub(rawName, "%z+$", ""))
	local compressedLen = s:u32()
	local uncompressedLen = s:u32()
	s:skip(4) -- reserved

	local body: buffer
	if compressedLen == 0 then
		body = s:take(uncompressedLen)
	else
		local start = s.pos
		if ZSTD.isZstd(s.buf, start) then
			body = ZSTD.decompress(s.buf, start, compressedLen, uncompressedLen)
		else
			body = LZ4.decompress(s.buf, start, compressedLen, uncompressedLen)
		end
		s:skip(compressedLen)
	end

	if buffer.len(body) ~= uncompressedLen then
		warn_(`chunk "{name}" decompressed to {buffer.len(body)} bytes, header said {uncompressedLen}`)
	end

	return { name = name, data = Stream.fromBuffer(body) }
end

local function readBinaryString(s: Stream): string
	local len = s:u32()
	return if len > 0 then s:str(len) else ""
end

-- ------------------------------------------------------------- DOM decode

function Decoder.decodeDom(input: buffer | string, options: DecodeOptions?): Dom
	local opts = options or {}
	local warn_ = opts.onWarning or function(msg: string)
		warn(`[RbxmSerializer] {msg}`)
	end

	local s = if type(input) == "string" then Stream.fromString(input) else Stream.fromBuffer(input)

	if s:str(8) ~= MAGIC then
		error("RbxmSerializer: not a binary Roblox file (bad magic number)")
	end
	if s:str(6) ~= SIGNATURE then
		error("RbxmSerializer: bad file signature")
	end
	local version = s:u16()
	if version ~= 0 then
		warn_(`file declares version {version}; only version 0 is understood`)
	end
	local declaredClassCount = s:i32()
	local declaredInstanceCount = s:i32()
	s:skip(8) -- reserved

	local dom: Dom = {
		metadata = {},
		sharedStrings = {},
		instances = {},
		classes = {},
		roots = {},
		order = {},
	}

	local classes: { [number]: DomClass } = {}
	local parentLinks: { { number } } = {}
	local sharedStringProps: { { inst: DomInstance, key: string } } = {}
	local pendingContent: { { inst: DomInstance, key: string } } = {}

	while true do
		local chunk = readChunk(s, warn_)
		if not chunk then
			break
		end
		local d = chunk.data

		if chunk.name == "META" then
			local count = d:u32()
			for _ = 1, count do
				local key = readBinaryString(d)
				dom.metadata[key] = readBinaryString(d)
			end
		elseif chunk.name == "SSTR" then
			d:u32() -- version
			local count = d:u32()
			for i = 1, count do
				d:skip(16) -- md5 hash, ignored by Studio
				dom.sharedStrings[i] = readBinaryString(d)
			end
		elseif chunk.name == "INST" then
			local classId = d:u32()
			local className = readBinaryString(d)
			local objectFormat = d:u8()
			local instanceCount = d:u32()
			local referents = DataTypes.read[TypeId.Referent](d, instanceCount) :: { number }
			if objectFormat == 1 then
				d:skip(instanceCount) -- service markers, all 1
			end

			local class: DomClass = {
				classId = classId,
				className = className,
				referents = referents,
				isService = objectFormat == 1,
				propertyOrder = {},
				propertyTypes = {},
			}
			classes[classId] = class
			table.insert(dom.classes, class)

			for _, ref in referents do
				local node: DomInstance = {
					referent = ref,
					className = className,
					isService = objectFormat == 1,
					properties = {},
					propertyTypes = class.propertyTypes,
					children = {},
					parentReferent = -1,
				}
				dom.instances[ref] = node
				table.insert(dom.order, ref)
			end
		elseif chunk.name == "PROP" then
			local classId = d:u32()
			local propName = readBinaryString(d)
			local typeId = d:u8()

			local class = classes[classId]
			if not class then
				warn_(`PROP chunk references unknown class id {classId}; skipping`)
				continue
			end

			local reader = DataTypes.read[typeId]
			if not reader then
				warn_(
					`property "{class.className}.{propName}" uses unsupported type id `
						.. `0x{string.format("%02x", typeId)}; skipping`
				)
				continue
			end

			if class.propertyTypes[propName] == nil then
				table.insert(class.propertyOrder, propName)
			end
			class.propertyTypes[propName] = typeId

			local count = #class.referents
			local ok, values = pcall(reader, d, count)
			if not ok then
				warn_(`failed to read "{class.className}.{propName}": {values}`)
				continue
			end

			for i, ref in class.referents do
				local node = dom.instances[ref]
				if node then
					local v = (values :: { any })[i]
					node.properties[propName] = v
					if typeId == TypeId.SharedString then
						table.insert(sharedStringProps, { inst = node, key = propName })
					elseif typeId == TypeId.Content then
						table.insert(pendingContent, { inst = node, key = propName })
					end
					if typeId == TypeId.Referent then
						node.properties["\0ref\0" .. propName] = true
					end
				end
			end
		elseif chunk.name == "PRNT" then
			d:u8() -- version
			local count = d:u32()
			local children = DataTypes.read[TypeId.Referent](d, count) :: { number }
			local parents = DataTypes.read[TypeId.Referent](d, count) :: { number }
			for i = 1, count do
				table.insert(parentLinks, { children[i], parents[i] })
			end
		elseif chunk.name == "END" then
			break
		else
			warn_(`unrecognised chunk "{chunk.name}"; skipping`)
		end
	end

	-- resolve shared strings
	for _, entry in sharedStringProps do
		local idx = entry.inst.properties[entry.key]
		if type(idx) == "number" then
			entry.inst.properties[entry.key] = dom.sharedStrings[idx] or ""
		end
	end

	-- hierarchy
	for _, link in parentLinks do
		local childRef, parentRef = link[1], link[2]
		local child = dom.instances[childRef]
		if not child then
			warn_(`PRNT references unknown child referent {childRef}`)
			continue
		end
		child.parentReferent = parentRef
		if parentRef == -1 then
			table.insert(dom.roots, child)
		else
			local parent = dom.instances[parentRef]
			if parent then
				table.insert(parent.children, child)
			else
				warn_(`PRNT references unknown parent referent {parentRef}`)
				table.insert(dom.roots, child)
			end
		end
	end

	local actualClasses = 0
	for _ in classes do
		actualClasses += 1
	end
	if declaredClassCount ~= actualClasses then
		warn_(`header declared {declaredClassCount} classes but {actualClasses} INST chunks were present`)
	end
	if declaredInstanceCount ~= #dom.order then
		warn_(`header declared {declaredInstanceCount} instances but {#dom.order} were present`)
	end

	local _ = pendingContent
	return dom
end

-- ---------------------------------------------------- DOM -> live Instances

local function buildReverseNames(className: string, sample: Instance): { [string]: string }
	local map = {}
	local ok, descriptors = pcall(Reflection.descriptorsFor, sample)
	if ok then
		for _, d in descriptors do
			map[d.serialized] = d.name
		end
	end
	local _ = className
	return map
end

local function applyValue(
	instance: Instance,
	luaName: string,
	value: any,
	refMap: { [number]: Instance },
	warn_: (string) -> ()
)
	local current: any
	local okRead = pcall(function()
		current = (instance :: any)[luaName]
	end)

	local final: any = value

	if type(value) == "table" and value.__kind == "PhysicalProperties" then
		-- AcousticAbsorption and the raw flag bits live in the DOM; the
		-- Roblox type only takes the five classic fields.
		if value.custom then
			final = PhysicalProperties.new(
				value.density,
				value.friction,
				value.elasticity,
				value.frictionWeight,
				value.elasticityWeight
			)
		else
			final = nil
		end
	elseif type(value) == "table" and value.__kind == "Font" then
		local weightEnum = Enum.FontWeight.Regular
		for _, item in Enum.FontWeight:GetEnumItems() do
			if item.Value == value.weight then
				weightEnum = item
				break
			end
		end
		local styleEnum = if value.style == 1 then Enum.FontStyle.Italic else Enum.FontStyle.Normal
		local okFont, font = pcall(Font.new, value.family, weightEnum, styleEnum)
		if not okFont then
			warn_(`could not rebuild Font for {instance.ClassName}.{luaName}`)
			return
		end
		final = font
	elseif typeof(value) == "number" and okRead and typeof(current) == "EnumItem" then
		-- Enum column: recover the EnumItem from the raw value
		local enumType = current.EnumType
		local found: EnumItem? = nil
		for _, item in enumType:GetEnumItems() do
			if item.Value == value then
				found = item
				break
			end
		end
		if not found then
			return
		end
		final = found
	elseif value == false and okRead and typeof(current) == "PhysicalProperties" then
		final = nil
	end

	local ok, err = pcall(function()
		(instance :: any)[luaName] = final
	end)
	if not ok then
		warn_(`could not set {instance.ClassName}.{luaName}: {err}`)
	end
	local _ = refMap
end

export type BuildResult = {
	roots: { Instance },
	byReferent: { [number]: Instance },
	dom: Dom,
}

function Decoder.build(dom: Dom, options: DecodeOptions?): BuildResult
	local opts = options or {}
	local warn_ = opts.onWarning or function(msg: string)
		warn(`[RbxmSerializer] {msg}`)
	end
	local applyAttributes = opts.applyAttributes ~= false
	local applyTags = opts.applyTags ~= false

	local byReferent: { [number]: Instance } = {}
	local reverseCache: { [string]: { [string]: string } } = {}

	-- pass 1: create
	for _, ref in dom.order do
		local node = dom.instances[ref]
		local ok, inst = pcall(Instance.new, node.className)
		if not ok then
			warn_(`cannot create an instance of "{node.className}"; substituting a Folder`)
			inst = Instance.new("Folder")
			inst.Name = node.className
		end
		byReferent[ref] = inst :: Instance
	end

	-- pass 2: properties
	local deferredRefs: { { inst: Instance, name: string, target: number } } = {}

	for _, ref in dom.order do
		local node = dom.instances[ref]
		local inst = byReferent[ref]

		local reverse = reverseCache[node.className]
		if not reverse then
			reverse = buildReverseNames(node.className, inst)
			reverseCache[node.className] = reverse
		end

		for serialized, value in node.properties do
			if string.sub(serialized, 1, 1) == "\0" then
				continue
			end

			if serialized == "AttributesSerialize" then
				if applyAttributes and type(value) == "string" and #value > 0 then
					for name, attrValue in Attributes.decode(value) do
						pcall(function()
							inst:SetAttribute(name, attrValue)
						end)
					end
				end
				continue
			end

			if serialized == "Tags" then
				if applyTags and type(value) == "string" and #value > 0 then
					for tag in string.gmatch(value, "[^%z]+") do
						pcall(function()
							CollectionService:AddTag(inst, tag)
						end)
					end
				end
				continue
			end

			local luaName = reverse[serialized] or serialized

			-- a referent-typed property arrives as a number
			if node.properties["\0ref\0" .. serialized] then
				if type(value) == "number" and value >= 0 then
					table.insert(deferredRefs, { inst = inst, name = luaName, target = value })
				end
				continue
			end

			if type(value) == "table" and (value :: any).sourceType ~= nil then
				-- Content value
				local st = (value :: any).sourceType
				if st == 1 then
					local okC, content = pcall(function()
						return (Content :: any).fromUri((value :: any).uri)
					end)
					if okC then
						applyValue(inst, luaName, content, byReferent, warn_)
					end
				end
				continue
			end

			applyValue(inst, luaName, value, byReferent, warn_)
		end
	end

	-- pass 3: instance references
	for _, entry in deferredRefs do
		local target = byReferent[entry.target]
		if target then
			local ok, err = pcall(function()
				(entry.inst :: any)[entry.name] = target
			end)
			if not ok then
				warn_(`could not set reference {entry.inst.ClassName}.{entry.name}: {err}`)
			end
		end
	end

	-- pass 4: parenting, children first
	for _, ref in dom.order do
		local node = dom.instances[ref]
		if node.parentReferent ~= -1 then
			local parent = byReferent[node.parentReferent]
			if parent then
				pcall(function()
					byReferent[ref].Parent = parent
				end)
			end
		end
	end

	local roots: { Instance } = {}
	for _, node in dom.roots do
		table.insert(roots, byReferent[node.referent])
	end

	return { roots = roots, byReferent = byReferent, dom = dom }
end

function Decoder.decode(input: buffer | string, options: DecodeOptions?): { Instance }
	local dom = Decoder.decodeDom(input, options)
	return Decoder.build(dom, options).roots
end

return Decoder
