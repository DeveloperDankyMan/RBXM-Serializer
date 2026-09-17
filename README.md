# RbxmSerializer

A reader and writer for Roblox's binary model format (`.rbxm` / `.rbxl`), written as a Luau ModuleScript. It implements the format described in [Roblox Binary Model Format, Version 0](https://dom.rojo.space/binary.html) and the companion [attribute blob format](https://github.com/rojo-rbx/rbx-dom/blob/master/docs/attributes.md).

No schema, no type constructors — you hand it Instances and it gives you bytes, you hand it bytes and it gives you Instances.

## Layout

```
RbxmSerializer/
  init.luau          public API
  Stream.luau        growable buffer cursor, LE + BE primitives
  Transforms.luau    zig-zag int transforms, byte interleaving, Roblox float format
  LZ4.luau           LZ4 block compressor + decompressor
  ZSTD.luau          ZSTD frame parsing, raw/RLE blocks, pluggable decoder hook
  MD5.luau           SSTR hash field
  DataTypes.luau     one reader + one writer per binary type ID
  Attributes.luau    AttributesSerialize blob encode/decode
  Reflection.luau    class -> property descriptors (API dump, built-ins, runtime probe)
  Decoder.luau       bytes -> DOM -> Instances
  Encoder.luau       Instances -> bytes
```

Drop the folder in, rename `init.luau` appropriately for your sync tool (Rojo picks it up as the folder's ModuleScript automatically).

## Usage

```lua
local RbxmSerializer = require(script.RbxmSerializer)

-- write
local bytes = RbxmSerializer.serialize(workspace.MyModel)
local str   = RbxmSerializer.serializeToString({ modelA, modelB })

-- read
local roots = RbxmSerializer.deserialize(bytes)
for _, root in roots do
    root.Parent = workspace
end

-- inspect without building anything
local dom = RbxmSerializer.readDom(bytes)
print(dom.metadata.ExplicitAutoJoints, #dom.roots)
for _, node in dom.roots do
    print(node.className, node.properties.Name)
end

-- lossless pass-through: file -> DOM -> file
local dom = RbxmSerializer.readDom(bytes)
dom.roots[1].properties.Name = "Renamed"
local out = RbxmSerializer.Encoder.encodeDom(dom)
```

### The two write paths

`serialize` goes from live Instances and depends on the reflection database:
Luau gives you no way to enumerate an Instance's properties, so anything the
database doesn't know about is not written.

`Encoder.encodeDom` goes straight from a decoded DOM and consults no
reflection at all, because the file already declared the name and type id of
every property. That is the pass-through path: properties this module has
never heard of, and ones Luau cannot set (`UniqueId`, `Tags`,
`AttributesSerialize`, `MeshData`, CSG blobs) all survive untouched.
Referents are renumbered densely in pre-order and `Referent`-typed values are
remapped to match, so a hand-edited DOM stays internally consistent.

Verified against a test vector covering 29 of the 30 property types: every
chunk re-encodes byte-identically except `SSTR`, where this module writes real
MD5 hashes. Re-decoding its own output is a fixed point.

### Encode options

| Option | Default | Meaning |
| --- | --- | --- |
| `compression` | `"lz4"` | `"lz4"` or `"none"`. Uncompressed chunks are legal and load fine. |
| `compressionLevel` | `1` | 1–16. Higher searches more match candidates per position. |
| `metadata` | `{ ExplicitAutoJoints = "true" }` | Written to the `META` chunk. |
| `includeAttributes` | `true` | Build `AttributesSerialize` from `GetAttributes`. |
| `includeTags` | `true` | Build `Tags` from `CollectionService:GetTags`. |
| `onWarning` | `warn` | Called with a message instead of warning. |

### Decode options

| Option | Default | Meaning |
| --- | --- | --- |
| `applyAttributes` | `true` | Call `SetAttribute` for each decoded attribute. |
| `applyTags` | `true` | Call `CollectionService:AddTag` for each decoded tag. |
| `onWarning` | `warn` | Called with a message instead of warning. |

## Reflection, and why you want an API dump

Roblox gives Lua no way to ask "what properties does this class have?". Encoding needs that answer, plus each property's *serialized* name and binary type — and those differ from the Lua-facing names more often than you'd expect (`BasePart.Size` is stored as `size`, `BasePart.Color` as `Color3uint8`, `Part.Shape` as `shape`, `BasePart.FormFactor` as `formFactorRaw`).

`Reflection.luau` answers in three layers:

1. **An API dump you supply.** Authoritative. Fetch the current dump JSON and feed the decoded table in once at startup:

   ```lua
   local dump = HttpService:JSONDecode(dumpJson)
   RbxmSerializer.loadApiDump(dump)
   ```

   The dump is the file Roblox publishes as `API-Dump.json` alongside each Studio release; `rbx-dom` also ships a maintained copy. Properties are taken when `Serialization.CanSave` is true, and `Serialization.SerializedName` is used when present.

2. **A built-in descriptor table**, resolved through `IsA` so subclasses inherit. `MeshPart`, `WedgePart`, `TrussPart` and `UnionOperation` all pick up everything registered under `BasePart` without needing their own entries. This covers parts, models, joints, constraints, scripts, value objects, GUI basics, lights, sounds, particles, beams, humanoids, tools, terrain and unions.

3. **Runtime probing.** Every candidate is read once on a live instance; anything that errors is dropped and cached out. This is what keeps the module from breaking when Roblox retires a property.

Without a dump you get layer 2 + 3, which round-trips common content correctly but will not carry properties the built-in table has never heard of. With a dump you get everything the engine is willing to save.

## Compression

Chunk bodies are LZ4 or ZSTD, chosen by sniffing the first four bytes (`28 b5 2f fd` means ZSTD).

**LZ4** is implemented in full, both directions. The compressor is a hash-table matcher honouring the end-of-block rules (last 5 bytes literal, last match ≥ 12 bytes from the end); `compressionLevel` controls how many candidates per position get checked. If compression doesn't shrink a chunk, the encoder falls back to storing it with compressed length 0, which the format explicitly allows.

**ZSTD** is partly implemented. Frame headers, Raw blocks and RLE blocks are decoded natively. Compressed blocks need FSE and Huffman entropy decoding, which is a project on its own and would be painfully slow in pure Luau, so they route through a hook instead:

```lua
RbxmSerializer.ZSTD.setDecompressor(function(compressed: buffer, uncompressedSize: number): buffer
    return MyZstdLibrary.decompress(compressed, uncompressedSize)
end)
```

This module only ever *writes* LZ4 or uncompressed chunks, which Studio accepts everywhere, so the ZSTD path only matters for reading newer files that were written that way.

## Format notes worth knowing

- **Interleaving.** Array-valued properties are stored byte-column-major, not value-by-value. `Transforms.readInterleaved` / `writeInterleaved` handle the general case; `Int32`, `Float32`, `Int64` and `u32` have direct helpers.
- **The Roblox float.** `Float32` columns move the sign bit to the *end* of the word: `eeeeeeee mmmmmmmm mmmmmmmm mmmmmmms`. `Float64`, `Ray`, sequences and `NumberRange` all use standard little-endian IEEE-754 instead.
- **Referents accumulate.** Each value in a referent array is a delta from the previous one. The encoder writes deltas; the decoder sums them.
- **CFrames get special-cased.** 24 axis-aligned rotations are stored as a single ID byte with no matrix. The encoder detects these (every matrix entry is 0 or ±1) and emits the short form; anything else writes the full nine floats.
- **PROP chunks are per-class columns.** Every instance of a class must specify the same properties, so the encoder reads a value for each instance and falls back to a type-appropriate default when a read fails, rather than dropping the column for everyone.
- **PRNT ordering.** Studio applies parent links in file order, and parenting can trigger engine side effects, so entries are written in depth-first post-order — descendants before ancestors.
- **The END chunk is never compressed.** It's used as a validation marker on upload.
- **Attributes have their own type numbering.** `String` is `0x01` in the model format but `0x02` in the attribute blob. `Attributes.luau` keeps the two tables separate deliberately.

## Known limits

- `Bytecode` (`0x1D`) is read and written verbatim and never interpreted. Running unsigned Luau bytecode hands whoever wrote it full access to the machine running it; don't.
- `UniqueId` values round-trip as opaque 16-byte records. Studio regenerates them on load anyway.
- `SecurityCapabilities` is stored as a 64-bit bitfield; it round-trips, but the engine's capability semantics aren't modelled.
- `Content` object references (`sourceType == 2`) only appear from copy-paste inside Studio and are decoded but not reattached.
- `PhysicalProperties` and `Font` live in the DOM as plain tables rather than
  the Roblox types, because `PhysicalProperties` has no field for
  `AcousticAbsorption` and `Font` has none for `CachedFaceId`. They are
  converted to real values on the way into an Instance; going through the DOM
  keeps both fields intact.
- Values above 2^53 in `Int64` columns lose precision, since Luau numbers are doubles. `Transforms.transformI64` / `untransformI64` expose the hi/lo halves if you need exactness.
