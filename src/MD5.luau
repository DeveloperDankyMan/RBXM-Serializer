--!strict
--!native
--[[
	MD5.luau

	Used only for the 16-byte hash field of `SSTR` entries. Roblox Studio
	ignores this field when loading, but real files carry it, so we produce
	it too for byte-level fidelity.
]]

local MD5 = {}

local S = {
	7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
	5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
	4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
	6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
}

local K = table.create(64)
for i = 1, 64 do
	K[i] = math.floor(math.abs(math.sin(i)) * 4294967296) % 4294967296
end

--[[ Returns the 16-byte digest of `message` as a raw (binary) string. ]]
function MD5.digest(message: string): string
	local msgLen = #message
	local bitLenLow = (msgLen * 8) % 4294967296
	local bitLenHigh = math.floor(msgLen / 536870912) % 4294967296

	-- pad: 0x80, zeros, then 64-bit little-endian length
	local padLen = (56 - (msgLen + 1) % 64) % 64
	local totalLen = msgLen + 1 + padLen + 8
	local buf = buffer.create(totalLen)
	buffer.writestring(buf, 0, message, msgLen)
	buffer.writeu8(buf, msgLen, 0x80)
	buffer.fill(buf, msgLen + 1, 0, padLen)
	buffer.writeu32(buf, totalLen - 8, bitLenLow)
	buffer.writeu32(buf, totalLen - 4, bitLenHigh)

	local a0, b0, c0, d0 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476

	local M = table.create(16)
	for chunk = 0, totalLen - 1, 64 do
		for i = 0, 15 do
			M[i + 1] = buffer.readu32(buf, chunk + i * 4)
		end

		local A, B, C, D = a0, b0, c0, d0

		for i = 0, 63 do
			local F, g
			if i < 16 then
				F = bit32.bor(bit32.band(B, C), bit32.band(bit32.bnot(B), D))
				g = i
			elseif i < 32 then
				F = bit32.bor(bit32.band(D, B), bit32.band(bit32.bnot(D), C))
				g = (5 * i + 1) % 16
			elseif i < 48 then
				F = bit32.bxor(B, C, D)
				g = (3 * i + 5) % 16
			else
				F = bit32.bxor(C, bit32.bor(B, bit32.bnot(D)))
				g = (7 * i) % 16
			end

			F = (F + A + K[i + 1] + M[g + 1]) % 4294967296
			A = D
			D = C
			C = B
			B = (B + bit32.lshift(F, S[i + 1]) + bit32.rshift(F, 32 - S[i + 1])) % 4294967296
		end

		a0 = (a0 + A) % 4294967296
		b0 = (b0 + B) % 4294967296
		c0 = (c0 + C) % 4294967296
		d0 = (d0 + D) % 4294967296
	end

	local out = buffer.create(16)
	buffer.writeu32(out, 0, a0)
	buffer.writeu32(out, 4, b0)
	buffer.writeu32(out, 8, c0)
	buffer.writeu32(out, 12, d0)
	return buffer.readstring(out, 0, 16)
end

return MD5
