--!strict
--!native
--[[
	Transforms.luau

	The three "weird" storage tricks the binary format uses:

	  1. Integer transformation (zig-zag): (x << 1) ^ (x >> 31)
	  2. Byte interleaving: arrays are stored column-major by byte index
	  3. The Roblox float format: sign bit moved to the *end* of the word

	Everything here operates on plain Lua numbers + the Stream type.
]]

local Stream = require(script.Parent.Stream)

type Stream = Stream.Stream

local Transforms = {}

-- ------------------------------------------------------- integer transforms

-- (x << 1) ^ (x >> 31), operating on a signed 32-bit value.
function Transforms.transformI32(x: number): number
	if x >= 0 then
		return (x * 2) % 4294967296
	end
	return (-x * 2 - 1) % 4294967296
end

-- (x >> 1) ^ -(x & 1)
function Transforms.untransformI32(x: number): number
	if x % 2 == 0 then
		return x / 2
	end
	return -((x + 1) / 2)
end

-- 64-bit variants. Luau numbers are doubles, so magnitudes above 2^53 lose
-- precision; hi/lo helpers are exposed for callers that need exactness.
function Transforms.transformI64(x: number): (number, number)
	local t: number
	if x >= 0 then
		t = x * 2
	else
		t = -x * 2 - 1
	end
	local hi = math.floor(t / 4294967296) % 4294967296
	local lo = t % 4294967296
	return hi, lo
end

function Transforms.untransformI64(hi: number, lo: number): number
	local odd = lo % 2 == 1
	-- logical shift right by one across the 64-bit word
	local shiftedLo = bit32.bor(bit32.rshift(lo, 1), bit32.lshift(bit32.band(hi, 1), 31))
	local shiftedHi = bit32.rshift(hi, 1)
	local value = shiftedHi * 4294967296 + shiftedLo
	if odd then
		return -(value + 1)
	end
	return value
end

-- ----------------------------------------------------------- roblox float32

local scratch = buffer.create(4)

-- Roblox layout: eeeeeeee mmmmmmmm mmmmmmmm mmmmmmms  (sign bit last)
function Transforms.decodeRobloxFloat(raw: number): number
	local sign = bit32.band(raw, 1)
	local rest = bit32.rshift(raw, 1)
	local ieee = bit32.bor(bit32.lshift(sign, 31), rest)
	buffer.writeu32(scratch, 0, ieee)
	return buffer.readf32(scratch, 0)
end

function Transforms.encodeRobloxFloat(value: number): number
	buffer.writef32(scratch, 0, value)
	local ieee = buffer.readu32(scratch, 0)
	local sign = bit32.rshift(ieee, 31)
	local rest = bit32.band(ieee, 0x7FFFFFFF)
	return bit32.bor(bit32.lshift(rest, 1), sign) % 4294967296
end

-- Reinterpret helpers for plain IEEE-754 f32 <-> u32.
function Transforms.f32ToBits(value: number): number
	buffer.writef32(scratch, 0, value)
	return buffer.readu32(scratch, 0)
end

function Transforms.bitsToF32(bits: number): number
	buffer.writeu32(scratch, 0, bits)
	return buffer.readf32(scratch, 0)
end

-- --------------------------------------------------------- byte interleaving

--[[
	Reads `count` values of `width` bytes each, stored column-major.
	Returns a flat buffer of count*width bytes in natural (row-major) order.
]]
function Transforms.readInterleaved(stream: Stream, count: number, width: number): buffer
	local total = count * width
	local src = stream:take(total)
	local out = buffer.create(total)
	for col = 0, width - 1 do
		local base = col * count
		for i = 0, count - 1 do
			buffer.writeu8(out, i * width + col, buffer.readu8(src, base + i))
		end
	end
	return out
end

--[[ Inverse of readInterleaved: `data` is row-major, write it column-major. ]]
function Transforms.writeInterleaved(stream: Stream, data: buffer, count: number, width: number)
	local total = count * width
	local tmp = buffer.create(total)
	for col = 0, width - 1 do
		local base = col * count
		for i = 0, count - 1 do
			buffer.writeu8(tmp, base + i, buffer.readu8(data, i * width + col))
		end
	end
	stream:wbuf(tmp, 0, total)
end

-- Convenience: interleaved array of big-endian u32s.
function Transforms.readInterleavedU32(stream: Stream, count: number): { number }
	local raw = Transforms.readInterleaved(stream, count, 4)
	local out = table.create(count)
	for i = 0, count - 1 do
		local p = i * 4
		out[i + 1] = buffer.readu8(raw, p) * 16777216
			+ buffer.readu8(raw, p + 1) * 65536
			+ buffer.readu8(raw, p + 2) * 256
			+ buffer.readu8(raw, p + 3)
	end
	return out
end

function Transforms.writeInterleavedU32(stream: Stream, values: { number })
	local count = #values
	local raw = buffer.create(count * 4)
	for i = 1, count do
		local v = values[i] % 4294967296
		local p = (i - 1) * 4
		buffer.writeu8(raw, p, bit32.band(bit32.rshift(v, 24), 0xFF))
		buffer.writeu8(raw, p + 1, bit32.band(bit32.rshift(v, 16), 0xFF))
		buffer.writeu8(raw, p + 2, bit32.band(bit32.rshift(v, 8), 0xFF))
		buffer.writeu8(raw, p + 3, bit32.band(v, 0xFF))
	end
	Transforms.writeInterleaved(stream, raw, count, 4)
end

-- Interleaved array of Int32 values (zig-zag transformed, big endian).
function Transforms.readInterleavedI32(stream: Stream, count: number): { number }
	local raw = Transforms.readInterleavedU32(stream, count)
	for i = 1, count do
		raw[i] = Transforms.untransformI32(raw[i])
	end
	return raw
end

function Transforms.writeInterleavedI32(stream: Stream, values: { number })
	local tmp = table.create(#values)
	for i = 1, #values do
		tmp[i] = Transforms.transformI32(values[i])
	end
	Transforms.writeInterleavedU32(stream, tmp)
end

-- Interleaved array of Roblox-format float32 values.
function Transforms.readInterleavedF32(stream: Stream, count: number): { number }
	local raw = Transforms.readInterleavedU32(stream, count)
	for i = 1, count do
		raw[i] = Transforms.decodeRobloxFloat(raw[i])
	end
	return raw
end

function Transforms.writeInterleavedF32(stream: Stream, values: { number })
	local tmp = table.create(#values)
	for i = 1, #values do
		tmp[i] = Transforms.encodeRobloxFloat(values[i])
	end
	Transforms.writeInterleavedU32(stream, tmp)
end

-- Interleaved array of Int64 values (zig-zag transformed, big endian).
function Transforms.readInterleavedI64(stream: Stream, count: number): { number }
	local raw = Transforms.readInterleaved(stream, count, 8)
	local out = table.create(count)
	for i = 0, count - 1 do
		local p = i * 8
		local hi = buffer.readu8(raw, p) * 16777216
			+ buffer.readu8(raw, p + 1) * 65536
			+ buffer.readu8(raw, p + 2) * 256
			+ buffer.readu8(raw, p + 3)
		local lo = buffer.readu8(raw, p + 4) * 16777216
			+ buffer.readu8(raw, p + 5) * 65536
			+ buffer.readu8(raw, p + 6) * 256
			+ buffer.readu8(raw, p + 7)
		out[i + 1] = Transforms.untransformI64(hi, lo)
	end
	return out
end

function Transforms.writeInterleavedI64(stream: Stream, values: { number })
	local count = #values
	local raw = buffer.create(count * 8)
	for i = 1, count do
		local hi, lo = Transforms.transformI64(values[i])
		local p = (i - 1) * 8
		buffer.writeu8(raw, p, bit32.band(bit32.rshift(hi, 24), 0xFF))
		buffer.writeu8(raw, p + 1, bit32.band(bit32.rshift(hi, 16), 0xFF))
		buffer.writeu8(raw, p + 2, bit32.band(bit32.rshift(hi, 8), 0xFF))
		buffer.writeu8(raw, p + 3, bit32.band(hi, 0xFF))
		buffer.writeu8(raw, p + 4, bit32.band(bit32.rshift(lo, 24), 0xFF))
		buffer.writeu8(raw, p + 5, bit32.band(bit32.rshift(lo, 16), 0xFF))
		buffer.writeu8(raw, p + 6, bit32.band(bit32.rshift(lo, 8), 0xFF))
		buffer.writeu8(raw, p + 7, bit32.band(lo, 0xFF))
	end
	Transforms.writeInterleaved(stream, raw, count, 8)
end

return Transforms
