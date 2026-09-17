--!strict
--!native
--[[
	Stream.luau

	A growable read/write cursor over a Luau `buffer`.
	All multi-byte reads/writes default to little-endian (matching the buffer
	library); big-endian variants are suffixed `BE`.

	Reader:  Stream.fromBuffer(buf) / Stream.fromString(str)
	Writer:  Stream.new(capacityHint)
]]

local Stream = {}
Stream.__index = Stream

export type Stream = {
	buf: buffer,
	pos: number,
	size: number,

	-- reader
	u8: (Stream) -> number,
	i8: (Stream) -> number,
	u16: (Stream) -> number,
	i16: (Stream) -> number,
	u32: (Stream) -> number,
	i32: (Stream) -> number,
	u32BE: (Stream) -> number,
	f32: (Stream) -> number,
	f64: (Stream) -> number,
	str: (Stream, number) -> string,
	take: (Stream, number) -> buffer,
	skip: (Stream, number) -> (),
	remaining: (Stream) -> number,
	eof: (Stream) -> boolean,

	-- writer
	wu8: (Stream, number) -> (),
	wi8: (Stream, number) -> (),
	wu16: (Stream, number) -> (),
	wi16: (Stream, number) -> (),
	wu32: (Stream, number) -> (),
	wi32: (Stream, number) -> (),
	wu32BE: (Stream, number) -> (),
	wf32: (Stream, number) -> (),
	wf64: (Stream, number) -> (),
	wstr: (Stream, string) -> (),
	wbuf: (Stream, buffer, number?, number?) -> (),
	wzeros: (Stream, number) -> (),

	reserve: (Stream, number) -> (),
	finish: (Stream) -> buffer,
	tostring: (Stream) -> string,
}

local function make(buf: buffer, size: number): Stream
	return (setmetatable({ buf = buf, pos = 0, size = size }, Stream) :: any) :: Stream
end

function Stream.new(capacity: number?): Stream
	return make(buffer.create(math.max(capacity or 256, 16)), 0)
end

function Stream.fromBuffer(buf: buffer): Stream
	return make(buf, buffer.len(buf))
end

function Stream.fromString(s: string): Stream
	local b = buffer.fromstring(s)
	return make(b, buffer.len(b))
end

-- ---------------------------------------------------------------- internals

function Stream.reserve(self: Stream, n: number)
	local need = self.pos + n
	local cap = buffer.len(self.buf)
	if need <= cap then
		return
	end
	local newCap = cap
	repeat
		newCap = newCap * 2
	until newCap >= need
	local nb = buffer.create(newCap)
	buffer.copy(nb, 0, self.buf, 0, self.size)
	self.buf = nb
end

local function advance(self: Stream, n: number)
	self.pos += n
	if self.pos > self.size then
		self.size = self.pos
	end
end

local function bounds(self: Stream, n: number)
	if self.pos + n > self.size then
		error(
			`Stream: tried to read {n} byte(s) at offset {self.pos} but only {self.size - self.pos} remain`,
			3
		)
	end
end

-- ------------------------------------------------------------------ reading

function Stream.u8(self: Stream): number
	bounds(self, 1)
	local v = buffer.readu8(self.buf, self.pos)
	self.pos += 1
	return v
end

function Stream.i8(self: Stream): number
	bounds(self, 1)
	local v = buffer.readi8(self.buf, self.pos)
	self.pos += 1
	return v
end

function Stream.u16(self: Stream): number
	bounds(self, 2)
	local v = buffer.readu16(self.buf, self.pos)
	self.pos += 2
	return v
end

function Stream.i16(self: Stream): number
	bounds(self, 2)
	local v = buffer.readi16(self.buf, self.pos)
	self.pos += 2
	return v
end

function Stream.u32(self: Stream): number
	bounds(self, 4)
	local v = buffer.readu32(self.buf, self.pos)
	self.pos += 4
	return v
end

function Stream.i32(self: Stream): number
	bounds(self, 4)
	local v = buffer.readi32(self.buf, self.pos)
	self.pos += 4
	return v
end

function Stream.u32BE(self: Stream): number
	bounds(self, 4)
	local b = self.buf
	local p = self.pos
	self.pos += 4
	return buffer.readu8(b, p) * 16777216
		+ buffer.readu8(b, p + 1) * 65536
		+ buffer.readu8(b, p + 2) * 256
		+ buffer.readu8(b, p + 3)
end

function Stream.f32(self: Stream): number
	bounds(self, 4)
	local v = buffer.readf32(self.buf, self.pos)
	self.pos += 4
	return v
end

function Stream.f64(self: Stream): number
	bounds(self, 8)
	local v = buffer.readf64(self.buf, self.pos)
	self.pos += 8
	return v
end

function Stream.str(self: Stream, n: number): string
	bounds(self, n)
	local v = buffer.readstring(self.buf, self.pos, n)
	self.pos += n
	return v
end

function Stream.take(self: Stream, n: number): buffer
	bounds(self, n)
	local out = buffer.create(n)
	buffer.copy(out, 0, self.buf, self.pos, n)
	self.pos += n
	return out
end

function Stream.skip(self: Stream, n: number)
	bounds(self, n)
	self.pos += n
end

function Stream.remaining(self: Stream): number
	return self.size - self.pos
end

function Stream.eof(self: Stream): boolean
	return self.pos >= self.size
end

-- ------------------------------------------------------------------ writing

function Stream.wu8(self: Stream, v: number)
	Stream.reserve(self, 1)
	buffer.writeu8(self.buf, self.pos, v)
	advance(self, 1)
end

function Stream.wi8(self: Stream, v: number)
	Stream.reserve(self, 1)
	buffer.writei8(self.buf, self.pos, v)
	advance(self, 1)
end

function Stream.wu16(self: Stream, v: number)
	Stream.reserve(self, 2)
	buffer.writeu16(self.buf, self.pos, v)
	advance(self, 2)
end

function Stream.wi16(self: Stream, v: number)
	Stream.reserve(self, 2)
	buffer.writei16(self.buf, self.pos, v)
	advance(self, 2)
end

function Stream.wu32(self: Stream, v: number)
	Stream.reserve(self, 4)
	buffer.writeu32(self.buf, self.pos, v)
	advance(self, 4)
end

function Stream.wi32(self: Stream, v: number)
	Stream.reserve(self, 4)
	buffer.writei32(self.buf, self.pos, v)
	advance(self, 4)
end

function Stream.wu32BE(self: Stream, v: number)
	Stream.reserve(self, 4)
	local b, p = self.buf, self.pos
	buffer.writeu8(b, p, bit32.band(bit32.rshift(v, 24), 0xFF))
	buffer.writeu8(b, p + 1, bit32.band(bit32.rshift(v, 16), 0xFF))
	buffer.writeu8(b, p + 2, bit32.band(bit32.rshift(v, 8), 0xFF))
	buffer.writeu8(b, p + 3, bit32.band(v, 0xFF))
	advance(self, 4)
end

function Stream.wf32(self: Stream, v: number)
	Stream.reserve(self, 4)
	buffer.writef32(self.buf, self.pos, v)
	advance(self, 4)
end

function Stream.wf64(self: Stream, v: number)
	Stream.reserve(self, 8)
	buffer.writef64(self.buf, self.pos, v)
	advance(self, 8)
end

function Stream.wstr(self: Stream, s: string)
	local n = #s
	if n == 0 then
		return
	end
	Stream.reserve(self, n)
	buffer.writestring(self.buf, self.pos, s, n)
	advance(self, n)
end

function Stream.wbuf(self: Stream, src: buffer, offset: number?, count: number?)
	local off = offset or 0
	local n = count or (buffer.len(src) - off)
	if n <= 0 then
		return
	end
	Stream.reserve(self, n)
	buffer.copy(self.buf, self.pos, src, off, n)
	advance(self, n)
end

function Stream.wzeros(self: Stream, n: number)
	Stream.reserve(self, n)
	buffer.fill(self.buf, self.pos, 0, n)
	advance(self, n)
end

-- ------------------------------------------------------------------ finish

function Stream.finish(self: Stream): buffer
	local out = buffer.create(self.size)
	buffer.copy(out, 0, self.buf, 0, self.size)
	return out
end

function Stream.tostring(self: Stream): string
	return buffer.readstring(self.buf, 0, self.size)
end

return Stream
