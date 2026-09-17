--!strict
--!native
--[[
	LZ4.luau

	Pure-Luau implementation of the LZ4 *block* format (no frame header),
	which is what Roblox uses for compressed chunk bodies.

	Block layout, repeated until the input is exhausted:

	    token : u8   -- high nibble = literal length, low nibble = match length
	    [extra literal length bytes, 255-terminated]
	    literals
	    offset : u16 little-endian   (absent for the final sequence)
	    [extra match length bytes, 255-terminated]

	Match length is stored minus the 4-byte minimum.

	End-of-block restrictions honoured by the compressor:
	  * the last 5 bytes are always literals
	  * the last match must start at least 12 bytes before the end
]]

local LZ4 = {}

local MIN_MATCH = 4
local LAST_LITERALS = 5
local MF_LIMIT = 12
local HASH_BITS = 16
local HASH_SIZE = 2 ^ HASH_BITS

-- ------------------------------------------------------------ decompression

--[[
	Decompresses `src` (starting at `offset`, reading `compressedSize` bytes)
	into a buffer of exactly `decompressedSize` bytes.
]]
function LZ4.decompress(src: buffer, offset: number, compressedSize: number, decompressedSize: number): buffer
	local dst = buffer.create(decompressedSize)
	local sp = offset
	local sEnd = offset + compressedSize
	local dp = 0

	while sp < sEnd do
		local token = buffer.readu8(src, sp)
		sp += 1

		-- literals
		local litLen = bit32.rshift(token, 4)
		if litLen == 15 then
			while true do
				local b = buffer.readu8(src, sp)
				sp += 1
				litLen += b
				if b ~= 255 then
					break
				end
			end
		end

		if litLen > 0 then
			if sp + litLen > sEnd then
				error(`LZ4: literal run of {litLen} overruns the compressed block`)
			end
			if dp + litLen > decompressedSize then
				error("LZ4: literal run overruns the output buffer")
			end
			buffer.copy(dst, dp, src, sp, litLen)
			sp += litLen
			dp += litLen
		end

		if sp >= sEnd then
			break
		end

		-- match
		local matchOffset = buffer.readu16(src, sp)
		sp += 2
		if matchOffset == 0 then
			error("LZ4: match offset of zero")
		end

		local matchLen = bit32.band(token, 0x0F)
		if matchLen == 15 then
			while true do
				local b = buffer.readu8(src, sp)
				sp += 1
				matchLen += b
				if b ~= 255 then
					break
				end
			end
		end
		matchLen += MIN_MATCH

		local mp = dp - matchOffset
		if mp < 0 then
			error("LZ4: match offset points before the start of the output")
		end
		if dp + matchLen > decompressedSize then
			error("LZ4: match overruns the output buffer")
		end

		if matchOffset >= matchLen then
			-- non-overlapping, bulk copy is safe
			buffer.copy(dst, dp, dst, mp, matchLen)
			dp += matchLen
		else
			-- overlapping run; must copy byte by byte
			for _ = 1, matchLen do
				buffer.writeu8(dst, dp, buffer.readu8(dst, mp))
				dp += 1
				mp += 1
			end
		end
	end

	if dp ~= decompressedSize then
		error(`LZ4: produced {dp} bytes but {decompressedSize} were expected`)
	end
	return dst
end

-- -------------------------------------------------------------- compression

local function hash4(src: buffer, p: number): number
	-- Knuth-style multiplicative hash over a little-endian 4-byte word.
	local v = buffer.readu32(src, p)
	return bit32.rshift(v * 2654435761 % 4294967296, 32 - HASH_BITS)
end

local function countMatch(src: buffer, a: number, b: number, limit: number): number
	local n = 0
	while b + n < limit and buffer.readu8(src, a + n) == buffer.readu8(src, b + n) do
		n += 1
	end
	return n
end

local function writeLength(out: { number }, n: number, len: number): number
	local remaining = len
	while remaining >= 255 do
		n += 1
		out[n] = 255
		remaining -= 255
	end
	n += 1
	out[n] = remaining
	return n
end

--[[
	Compresses `src` into an LZ4 block. `level` (1..16) controls how far back
	the matcher will search; 1 is fastest, higher values compress a little
	better at a linear cost. Returns a buffer.

	If compression would not shrink the data, the caller should fall back to
	storing the chunk uncompressed (compressed length 0).
]]
function LZ4.compress(src: buffer, level: number?): buffer
	local srcLen = buffer.len(src)
	local out: { number } = table.create(math.max(srcLen // 2, 16))
	local n = 0

	if srcLen < MF_LIMIT + LAST_LITERALS then
		-- Too small to hold a match; emit one all-literal sequence.
		local litLen = srcLen
		local token = if litLen >= 15 then 0xF0 else litLen * 16
		n += 1
		out[n] = token
		if litLen >= 15 then
			n = writeLength(out, n, litLen - 15)
		end
		local res = buffer.create(n + srcLen)
		for i = 1, n do
			buffer.writeu8(res, i - 1, out[i])
		end
		buffer.copy(res, n, src, 0, srcLen)
		return res
	end

	local attempts = math.clamp(level or 1, 1, 16)
	local hashTable = table.create(HASH_SIZE, -1)
	-- chain[p] = previous position with the same hash (for level > 1)
	local chain: { number }? = if attempts > 1 then table.create(srcLen, -1) else nil

	local matchLimit = srcLen - LAST_LITERALS
	local searchLimit = srcLen - MF_LIMIT

	local anchor = 0
	local p = 0
	local literalChunks: { { number } } = {}

	local function flushLiterals(from: number, to: number, matchLen: number?, offset: number?)
		local litLen = to - from
		local ml = if matchLen then matchLen - MIN_MATCH else nil

		local tokenLit = if litLen >= 15 then 15 else litLen
		local tokenMatch = if ml then (if ml >= 15 then 15 else ml) else 0
		n += 1
		out[n] = tokenLit * 16 + tokenMatch

		if litLen >= 15 then
			n = writeLength(out, n, litLen - 15)
		end
		if litLen > 0 then
			-- literals are recorded as a (start, length) pair to copy later
			local marker = { -1, from, litLen }
			table.insert(literalChunks, marker)
			n += 1
			out[n] = -#literalChunks -- negative sentinel = literal blob index
		end
		if ml then
			local off = offset :: number
			n += 1
			out[n] = bit32.band(off, 0xFF)
			n += 1
			out[n] = bit32.rshift(off, 8)
			if ml >= 15 then
				n = writeLength(out, n, ml - 15)
			end
		end
	end

	while p < searchLimit do
		local h = hash4(src, p)
		local candidate = hashTable[h]

		local bestLen, bestOff = 0, 0
		local tries = attempts
		local cur = candidate
		while cur ~= nil and cur >= 0 and tries > 0 do
			local off = p - cur
			if off <= 0 or off > 65535 then
				break
			end
			if buffer.readu32(src, cur) == buffer.readu32(src, p) then
				local len = countMatch(src, cur, p, matchLimit)
				if len > bestLen then
					bestLen = len
					bestOff = off
				end
			end
			tries -= 1
			if chain then
				cur = chain[cur + 1]
			else
				cur = -1
			end
		end

		if chain then
			chain[p + 1] = hashTable[h]
		end
		hashTable[h] = p

		if bestLen >= MIN_MATCH then
			flushLiterals(anchor, p, bestLen, bestOff)
			-- index the interior of the match so later positions can find it
			local stop = math.min(p + bestLen, searchLimit)
			local q = p + 1
			while q < stop do
				local hh = hash4(src, q)
				if chain then
					chain[q + 1] = hashTable[hh]
				end
				hashTable[hh] = q
				q += 1
			end
			p += bestLen
			anchor = p
		else
			p += 1
		end
	end

	-- trailing literals
	flushLiterals(anchor, srcLen, nil, nil)

	-- materialise
	local total = 0
	for i = 1, n do
		local v = out[i]
		if v < 0 then
			total += literalChunks[-v][3]
		else
			total += 1
		end
	end

	local res = buffer.create(total)
	local w = 0
	for i = 1, n do
		local v = out[i]
		if v < 0 then
			local marker = literalChunks[-v]
			buffer.copy(res, w, src, marker[2], marker[3])
			w += marker[3]
		else
			buffer.writeu8(res, w, v)
			w += 1
		end
	end
	return res
end

return LZ4
