--!strict
--[[
	RbxmSerializer

	A full-fidelity reader and writer for Roblox's binary model format
	(`.rbxm` / `.rbxl`, "Roblox Binary Model Format, Version 0").

	    local RbxmSerializer = require(path.to.RbxmSerializer)

	    -- Instances -> bytes
	    local bytes = RbxmSerializer.serialize({ workspace.Model })
	    local str   = RbxmSerializer.serializeToString({ workspace.Model })

	    -- bytes -> Instances
	    local roots = RbxmSerializer.deserialize(bytes)
	    for _, root in roots do
	        root.Parent = workspace
	    end

	    -- bytes -> inspectable DOM (no Instances created)
	    local dom = RbxmSerializer.readDom(bytes)
	    print(dom.metadata, #dom.roots)

	Optional setup, both of which improve fidelity:

	    RbxmSerializer.loadApiDump(HttpService:JSONDecode(dumpJson))
	    RbxmSerializer.ZSTD.setDecompressor(myZstdDecoder)

	See README.md for the details of what each layer does and where the
	format's sharp edges are.
]]

local Decoder = require(script.Decoder)
local Encoder = require(script.Encoder)
local Reflection = require(script.Reflection)
local DataTypes = require(script.DataTypes)
local Attributes = require(script.Attributes)
local Transforms = require(script.Transforms)
local Stream = require(script.Stream)
local LZ4 = require(script.LZ4)
local ZSTD = require(script.ZSTD)
local MD5 = require(script.MD5)

export type Dom = Decoder.Dom
export type DomInstance = Decoder.DomInstance
export type DecodeOptions = Decoder.DecodeOptions
export type EncodeOptions = Encoder.EncodeOptions

local RbxmSerializer = {}

RbxmSerializer.VERSION = "1.0.0"
RbxmSerializer.FORMAT_VERSION = 0

-- ---------------------------------------------------------------- writing

--[[
	Serializes one instance or a list of instances into a buffer.

	Options:
	  compression        "lz4" (default) or "none"
	  compressionLevel   1..16, higher searches harder (default 1)
	  metadata           map written to the META chunk
	  includeAttributes  default true
	  includeTags        default true
	  onWarning          function(message) -- defaults to `warn`
]]
function RbxmSerializer.serialize(target: Instance | { Instance }, options: EncodeOptions?): buffer
	local roots: { Instance } = if typeof(target) == "Instance" then { target } else target :: { Instance }
	return Encoder.encode(roots, options)
end

function RbxmSerializer.serializeToString(target: Instance | { Instance }, options: EncodeOptions?): string
	local buf = RbxmSerializer.serialize(target, options)
	return buffer.tostring(buf)
end

-- ---------------------------------------------------------------- reading

--[[ Parses a file and returns its root instances, already built. ]]
function RbxmSerializer.deserialize(input: buffer | string, options: DecodeOptions?): { Instance }
	return Decoder.decode(input, options)
end

--[[ Parses a file into a DOM without touching the Instance API. ]]
function RbxmSerializer.readDom(input: buffer | string, options: DecodeOptions?): Dom
	return Decoder.decodeDom(input, options)
end

--[[ Builds Instances from a DOM you already have (or have edited). ]]
function RbxmSerializer.buildFromDom(dom: Dom, options: DecodeOptions?)
	return Decoder.build(dom, options)
end

--[[ Cheap check for whether some bytes look like a binary Roblox file. ]]
function RbxmSerializer.isBinaryModel(input: buffer | string): boolean
	local s = if type(input) == "string" then input else buffer.tostring(input)
	return string.sub(s, 1, 8) == "<roblox!"
end

-- ------------------------------------------------------------- reflection

function RbxmSerializer.loadApiDump(dump: any)
	Reflection.loadApiDump(dump)
	Reflection.clearCache()
end

function RbxmSerializer.clearApiDump()
	Reflection.clearApiDump()
	Reflection.clearCache()
end

-- ------------------------------------------------------- exposed internals

RbxmSerializer.Decoder = Decoder
RbxmSerializer.Encoder = Encoder
RbxmSerializer.Reflection = Reflection
RbxmSerializer.DataTypes = DataTypes
RbxmSerializer.Attributes = Attributes
RbxmSerializer.Transforms = Transforms
RbxmSerializer.Stream = Stream
RbxmSerializer.LZ4 = LZ4
RbxmSerializer.ZSTD = ZSTD
RbxmSerializer.MD5 = MD5

return RbxmSerializer
