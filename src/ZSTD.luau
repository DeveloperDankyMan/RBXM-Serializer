--!strict
--[[
	ZSTD.luau

	Roblox began emitting ZSTD-compressed chunks in newer files. A chunk body
	is ZSTD if its first four bytes are the frame magic `28 b5 2f fd`.

	A complete ZSTD decoder (FSE + Huffman entropy decoding, sequence
	execution, dictionary support) is a large project on its own, and a
	correct-but-slow pure-Luau version would stall on any real place file.
	What this module does:

	  * detects the frame magic
	  * parses the frame header
	  * decodes Raw and RLE blocks natively (these do appear in small chunks)
	  * for Compressed blocks, defers to a decompressor you install via
	    `ZSTD.setDecompressor`, and raises a clear error if none is installed

	Install a decoder like this:

	    local ZSTD = require(RbxmSerializer.ZSTD)
	    ZSTD.setDecompressor(function(compressed: buffer, uncompressedSize: number): buffer
	        return MyZstdLibrary.decompress(compressed, uncompressedSize)
	    end)

	Roblox Studio writes LZ4 for `.rbxm` model files in the common case, so
	most model round-trips never reach this path. The serializer in this
	package only ever *writes* LZ4 or uncompressed chunks, which Studio
	accepts everywhere.
]]

local ZSTD = {}

local MAGIC = { 0x28, 0xB5, 0x2F, 0xFD }

local external: ((buffer, number) -> buffer)? = nil

function ZSTD.setDecompressor(fn: ((buffer, number) -> buffer)?)
	external = fn
end

function ZSTD.hasDecompressor(): boolean
	return external ~= nil
end

function ZSTD.isZstd(buf: buffer, offset: number): boolean
	if buffer.len(buf) - offset < 4 then
		return false
	end
	for i = 0, 3 do
		if buffer.readu8(buf, offset + i) ~= MAGIC[i + 1] then
			return false
		end
	end
	return true
end

local function parseFrameHeader(buf: buffer, p: number): (number, boolean)
	-- returns (offset of first block header, singleSegment)
	local descriptor = buffer.readu8(buf, p)
	p += 1

	local frameContentSizeFlag = bit32.rshift(descriptor, 6)
	local singleSegment = bit32.band(bit32.rshift(descriptor, 5), 1) == 1
	local contentChecksum = bit32.band(bit32.rshift(descriptor, 2), 1) == 1
	local dictIdFlag = bit32.band(descriptor, 3)

	if not singleSegment then
		p += 1 -- window descriptor
	end

	local dictIdSize = ({ 0, 1, 2, 4 })[dictIdFlag + 1]
	p += dictIdSize

	local fcsSize = ({ 0, 2, 4, 8 })[frameContentSizeFlag + 1]
	if frameContentSizeFlag == 0 and singleSegment then
		fcsSize = 1
	end
	p += fcsSize

	local _ = contentChecksum
	return p, singleSegment
end

--[[
	Decompresses a ZSTD frame starting at `offset` in `src`, producing exactly
	`uncompressedSize` bytes.
]]
function ZSTD.decompress(src: buffer, offset: number, compressedSize: number, uncompressedSize: number): buffer
	if external then
		local slice = buffer.create(compressedSize)
		buffer.copy(slice, 0, src, offset, compressedSize)
		local out = external(slice, uncompressedSize)
		if buffer.len(out) ~= uncompressedSize then
			error(
				`ZSTD: installed decompressor returned {buffer.len(out)} bytes, expected {uncompressedSize}`
			)
		end
		return out
	end

	if not ZSTD.isZstd(src, offset) then
		error("ZSTD: missing frame magic")
	end

	local dst = buffer.create(uncompressedSize)
	local dp = 0
	local p = parseFrameHeader(src, offset + 4)
	local frameEnd = offset + compressedSize

	while p < frameEnd do
		local header = buffer.readu8(src, p) + buffer.readu8(src, p + 1) * 256 + buffer.readu8(src, p + 2) * 65536
		p += 3

		local lastBlock = bit32.band(header, 1) == 1
		local blockType = bit32.band(bit32.rshift(header, 1), 3)
		local blockSize = bit32.rshift(header, 3)

		if blockType == 0 then -- Raw
			buffer.copy(dst, dp, src, p, blockSize)
			dp += blockSize
			p += blockSize
		elseif blockType == 1 then -- RLE
			local byte = buffer.readu8(src, p)
			buffer.fill(dst, dp, byte, blockSize)
			dp += blockSize
			p += 1
		elseif blockType == 2 then -- Compressed
			error(
				"ZSTD: this chunk uses a compressed ZSTD block. Install a decoder with "
					.. "ZSTD.setDecompressor(fn) — see ZSTD.luau for details."
			)
		else
			error("ZSTD: reserved block type")
		end

		if lastBlock then
			break
		end
	end

	if dp ~= uncompressedSize then
		error(`ZSTD: produced {dp} bytes but {uncompressedSize} were expected`)
	end
	return dst
end

return ZSTD
