# Plan — `@safe` D Zstandard (ZSTD / RFC 8878) Compression and Decompression

This document defines the technical architecture and phased implementation plan
for adding **Zstandard (ZSTD)** compression and decompression (RFC 8878) to the
`zipd` workspace.

Like the existing DEFLATE/gzip implementation in `zipd`, the ZSTD codec and
framing layer will be written in 100% high-level `@safe` D with
`-preview=dip1000`, `Result!T` error handling, deterministic multicore output,
and zero `@trusted` code outside the single audited I/O and threading shim
(`packages/compressor/source/zipd/compressor/unsafe.d`).

---

## 1. Goals and Non-Goals

### 1.1 Goals

1. **Full RFC 8878 Frame and Block Decoder**:
   - Decode standard ZSTD frames (magic `0xFD2FB528`) and skippable frames
     (`0x184D2A50`..`0x184D2A5F`).
   - Support all four block types (`Raw_Block`, `RLE_Block`,
     `Compressed_Block`, and rejection of `Reserved`).
   - Support all four literals block types (`Raw_Literals_Block`,
     `RLE_Literals_Block`, `Compressed_Literals_Block`,
     `Treeless_Literals_Block`) in both 1-stream and 4-stream Huffman formats.
   - Support all four sequence compression modes (`Predefined_Mode`,
     `RLE_Mode`, `FSE_Compressed_Mode`, `Repeat_Mode`).
   - Track sliding-window history across blocks within a frame and maintain the
     three repeat offsets (`rep[0..3] = [1, 4, 8]`).
   - Validate the optional 32-bit `Content_Checksum` (low 32 bits of
     `XXH64(content, seed=0)`) and `Frame_Content_Size` when present.
   - Transparently decode concatenated ZSTD frames.
2. **Interoperable `@safe` D ZSTD Encoder**:
   - Emit RFC 8878 compliant ZSTD frames with `Content_Checksum_flag = 1` and
     deterministic headers.
   - Support `Raw_Block`, `RLE_Block`, and `Compressed_Block` emission with
     128 KiB maximum block size.
   - Implement LZ77 + repeat-offset match finding tuned for ZSTD's sequence
     cost model (`level 1..9`, extensible to higher levels).
   - Support both predefined FSE tables (`Predefined_Mode`) and dynamic FSE
     table construction (`FSE_Compressed_Mode`, `RLE_Mode`, `Repeat_Mode`), as
     well as dynamic 1-stream / 4-stream Huffman literal encoding.
3. **Multicore Scaling via Concatenated ZSTD Frames**:
   - Reuse and extend `zipd.compressor.scheduler` so each worker encodes an
     independent `chunkSize` slice into a complete ZSTD frame with its own
     content checksum, written in deterministic input order (matching
     `zstd -T` multi-frame streams).
4. **Strict Safety & Memory Guarantees**:
   - Compile with `-preview=dip1000`.
   - Maintain the CI grep invariants: zero `@system` anywhere in
     `packages/compressor` or `packages/compress-cli`, and zero `@trusted`
     outside `packages/compressor/source/zipd/compressor/unsafe.d`.
   - Avoid per-block heap churn in worker threads by reusing encoder/decoder
     workspaces.
5. **Seamless CLI & Library Integration**:
   - Add `CodecId.zstd` and `ContainerKind.zstd` to `zipd.compressor.settings`.
   - Support `--codec zstd` (and auto-detection by `.zst` file extension or
     frame magic bytes in `decompress`, `test`, and `info`).
   - Validate bidirectional interoperability against stock `zstd(1)` in
     `tests/compose.yml` and `tools/interop-test.sh`.

### 1.2 Non-Goals for v1

1. **External Dictionary Training and Dictionary ID Lookup**:
   - Frames requesting a non-zero `Dictionary_ID` will return
     `ErrorKind.unsupported` ("ZSTD dictionary frames are not supported in v1").
   - Dictionary generation (`zstd --train`) is out of scope.
2. **Assembly / SIMD Intrinsics**:
   - All bitstream, FSE, Huffman, and match-finder routines must be written in
     portable `@safe` D without inline assembly or pointer casts.
3. **Modifying or Destabilizing DEFLATE/gzip**:
   - Existing gzip/DEFLATE paths and tests must remain 100% green and
     backward-compatible.

---

## 2. RFC 8878 Specification Summary

### 2.1 Frame Structure

A ZSTD stream consists of one or more concatenated frames. Each frame is either
a **Zstandard Frame** or a **Skippable Frame**:

```text
+--------------------+------------------------+-----------------------+--------------------+
| Magic_Number (4B)  | Frame_Header (2..14B)  | Data_Block (1..N)     | Content_Checksum   |
| 0xFD2FB528 (LE)    | Descriptor + Win + FCS | 3B Header + Payload   | 0 or 4 Bytes (LE)  |
+--------------------+------------------------+-----------------------+--------------------+
```

- **Magic Number**: `0xFD2FB528` (little-endian bytes: `28 B5 2F FD`).
- **Frame_Header_Descriptor** (1 byte):
  - Bits `7..6`: `Frame_Content_Size_flag` (`0` = 0 or 1 byte if `Single_Segment_flag`, `1` = 2 bytes + 256, `2` = 4 bytes, `3` = 8 bytes).
  - Bit `5`: `Single_Segment_flag` (if `1`, `Window_Descriptor` is omitted and `Window_Size = Frame_Content_Size`).
  - Bit `4`: `Unused_bit` (encoder sets `0`).
  - Bit `3`: `Reserved_bit` (must be `0`; decoder rejects non-zero with `ErrorKind.corruptInput`).
  - Bit `2`: `Content_Checksum_flag` (if `1`, a 4-byte XXH64 low-32-bit checksum follows the final block).
  - Bits `1..0`: `Dictionary_ID_flag` (`0` = 0B, `1` = 1B, `2` = 2B, `3` = 4B).
- **Window_Descriptor** (0 or 1 byte, present if `!Single_Segment_flag`):
  - `Exponent = byte >> 3` (5 bits), `Mantissa = byte & 7` (3 bits).
  - `Window_Base = 1UL << (10 + Exponent)`.
  - `Window_Size = Window_Base + (Window_Base >> 3) * Mantissa`.
  - Minimum window size is 1 KiB; decoder caps maximum allowed window size at a
    configurable safety limit (e.g., 128 MiB default, matching `zstd` security
    recommendations).
- **Skippable Frame**:
  - Magic `0x184D2A50`..`0x184D2A5F` (4B LE) + `Frame_Size` (4B LE uint) +
    `Frame_Size` user bytes ignored by decoder.

### 2.2 Block Structure

Each block starts with a 3-byte little-endian header:

- Bit `0`: `Last_Block` (`1` if final block in frame).
- Bits `2..1`: `Block_Type`:
  - `0` = `Raw_Block` (uncompressed `Block_Size` bytes).
  - `1` = `RLE_Block` (1 byte in stream, repeated `Block_Size` times in output).
  - `2` = `Compressed_Block` (`Block_Size` compressed bytes; decompressed size $\le \min(\text{Window\_Size}, 128\text{ KiB})$).
  - `3` = `Reserved` (invalid; reject with `ErrorKind.corruptInput`).
- Bits `23..3`: `Block_Size` (21-bit unsigned integer).
- Maximum `Block_Maximum_Size` is 128 KiB (`131_072` bytes). Any block whose
  compressed or uncompressed size exceeds `min(Window_Size, 128 KiB)` is
  rejected as corrupt.

### 2.3 Compressed Block Layout

A `Compressed_Block` contains two sequential sections:

1. **Literals_Section**:
   - `Literals_Block_Type` (2 bits):
     - `0` = `Raw_Literals_Block`
     - `1` = `RLE_Literals_Block`
     - `2` = `Compressed_Literals_Block` (includes a Huffman tree description)
     - `3` = `Treeless_Literals_Block` (reuses the previous block's Huffman tree within the same frame)
   - `Size_Format` (2 bits) + regeneration/compressed sizes (1 to 5 bytes total header).
   - Optional `Huffman_Tree_Description` (weights encoded via FSE or direct 4-bit nibbles; maximum code length = 11 bits).
   - 1-stream or 4-stream (with 6-byte jump table) backward-bitstream Huffman-coded literals.
2. **Sequences_Section**:
   - `Number_of_Sequences` (1 to 3 bytes; `0` means the block consists solely of the decoded literals).
   - `Symbol_Compression_Modes` byte (bits `7..6` = `Literals_Lengths_Mode`, bits `5..4` = `Offsets_Mode`, bits `3..2` = `Match_Lengths_Mode`, bits `1..0` = `0` reserved).
   - Mode values: `0` = `Predefined_Mode`, `1` = `RLE_Mode`, `2` = `FSE_Compressed_Mode`, `3` = `Repeat_Mode`.
   - Optional FSE table descriptions for any table using `FSE_Compressed_Mode` (or single symbol byte for `RLE_Mode`).
   - Single interleaved backward bitstream encoding initial FSE states (`LL`, `OF`, `ML`) followed by extra bits and FSE state update bits per sequence.

### 2.4 Sequence Execution & Repeat Offsets

Each frame initializes:

- Repeat offsets: `rep = [1, 4, 8]`.
- Previous Huffman tree: empty (`hasHuffmanTree = false`).
- Previous FSE tables (`LL`, `ML`, `OF`): uninitialized (`hasFseTables = false`).

For each decoded sequence `(litLength, matchLength, offsetValue)`:

1. Copy `litLength` bytes from the decoded `Literals_Section` buffer to the output.
2. Resolve the actual back-reference `offset` from `offsetValue` and update `rep[0..3]`:
   - If `offsetValue > 3`:
     - `offset = offsetValue - 3`
     - `rep = [offset, rep[0], rep[1]]`
   - If `offsetValue == 1..3` and `litLength > 0`:
     - `idx = offsetValue - 1`
     - `offset = rep[idx]`
     - Update `rep` by moving `rep[idx]` to `rep[0]` and shifting earlier elements down.
   - If `offsetValue == 1..3` and `litLength == 0`:
     - If `offsetValue == 3`: `offset = rep[0] - 1` (if `rep[0] == 1`, stream is corrupt); `rep = [offset, rep[0], rep[1]]`.
     - If `offsetValue == 1`: `offset = rep[1]`; `rep = [rep[1], rep[0], rep[2]]`.
     - If `offsetValue == 2`: `offset = rep[2]`; `rep = [rep[2], rep[0], rep[1]]`.
3. Validate `offset >= 1`, `offset <= totalProducedInFrame`, and `offset <= Window_Size`.
4. Copy `matchLength` bytes from `output[currentPos - offset .. $]` (supporting overlapping byte-by-byte RLE/periodic copies when `offset < matchLength`).
5. After all sequences in the block are executed, copy any remaining trailing literals from the `Literals_Section` buffer to the output.

---

## 3. Proposed Package and Module Layout

All new ZSTD modules live alongside the existing DEFLATE/gzip modules in
`packages/compressor/source/zipd/compressor/`, adhering to the exact same
naming and visibility conventions:

```text
packages/
|-- compressor/
|   `-- source/zipd/compressor/
|       |-- package.d               // Re-exports public API
|       |-- errors.d                // Existing Result!T and ErrorKind
|       |-- settings.d              // Extended with CodecId.zstd, ContainerKind.zstd, CompressMode.zstd
|       |-- checksum.d              // Existing CRC32 + new Xxh64 / xxh64Low32
|       |-- bitwriter.d             // Existing forward LSB bit writer
|       |-- bitreader.d             // Existing forward LSB bit reader
|       |-- zstd_bitstream.d        // NEW: ZSTD backward bit reader & writer + forward header helpers
|       |-- zstd_tables.d           // NEW: LL/ML/OF baseline & extra-bits tables, predefined FSE distributions
|       |-- zstd_fse.d              // NEW: FSE (tANS) table reader, builder, normalizer, encoder, decoder
|       |-- zstd_huffman.d          // NEW: ZSTD 11-bit Huffman weight encoding/decoding, 1-stream & 4-stream codecs
|       |-- zstd_sequences.d        // NEW: Sequence representation, repeat-offset state machine, sequence execution
|       |-- zstd_frame.d            // NEW: ZSTD frame header, block header, skippable frame, trailer parser/writer
|       |-- zstd_dec.d              // NEW: Stateful ZSTD frame & multi-frame decompressor
|       |-- zstd_lz.d               // NEW: ZSTD match finder (hash table / chain + repeat-offset matcher)
|       |-- zstd_enc.d              // NEW: ZSTD block & frame encoder (raw, RLE, compressed blocks)
|       |-- streaming.d             // Extended to dispatch gzip/DEFLATE vs ZSTD and auto-detect format on decode
|       |-- scheduler.d             // Extended to emit concatenated ZSTD frames in multicore mode
|       `-- unsafe.d                // UNCHANGED: single audited @trusted shim for File I/O and threads
`-- compress-cli/
    `-- source/zipd/cli/
        |-- args.d                  // Extended with --codec (deflate|zstd) and level normalization
        |-- commands.d              // Extended `info`, `compress`, `decompress`, `test` for ZSTD frames
        `-- exitcode.d              // Unchanged
```

---

## 4. Safety, Memory, and DIP1000 Design

### 4.1 Zero New `@trusted` Code

ZSTD requires **no additions** to `unsafe.d`:

- All bit manipulation, endian decoding (`ubyte[0] | (ubyte[1] << 8) ...`),
  XXH64 arithmetic, FSE state transitions, Huffman table lookups, and LZ77
  sliding window searches operate strictly on bounds-checked D arrays and
  slices (`scope const(ubyte)[]`, `scope ubyte[]`).
- No pointer casts (`cast(ulong*)` or `cast(uint*)`) are permitted. Little-endian
  32-bit and 64-bit loads/stores will be written as `@safe pure nothrow @nogc`
  inline helper functions over fixed-size byte ranges.
- The CI check in `tests/compose.yml` will continue to enforce:
  ```bash
  ! grep -RnE '\b@system\b'  packages/compressor packages/compress-cli
  ! grep -RnE '\b@trusted\b' packages/compressor packages/compress-cli \
    | grep -v 'compressor/unsafe.d'
  ```

### 4.2 DIP1000 and Lifetime Discipline

1. Every ZSTD module starts with `@safe:`.
2. Borrowed slice readers/writers (`ZstdBackBitReader`, `ZstdBackBitWriter`)
   annotate constructors with `return scope` and methods with `scope` exactly
   like [`BitReader`](file:///home/leonardo/Projetos/zipd/packages/compressor/source/zipd/compressor/bitreader.d#L20-L30)
   and [`BitWriter`](file:///home/leonardo/Projetos/zipd/packages/compressor/source/zipd/compressor/bitwriter.d#L21-L36).
3. Hot-path functions (`xxh64`, `fseDecodeSymbol`, `huffDecode1Stream`,
   `executeSequences`, etc.) are marked `pure nothrow @nogc @safe`.
4. All fallible operations return `Result!T` from [`zipd.compressor.errors`](file:///home/leonardo/Projetos/zipd/packages/compressor/source/zipd/compressor/errors.d#L48-L66);
   no exceptions are thrown in codec modules.

### 4.3 Reusable Workspace Allocation

To prevent GC pressure during multi-megabyte and multicore runs:

- **Decoder Workspace (`ZstdDecoderState`)**:
  - Holds fixed-size FSE decode tables (`LL` max 512 entries, `ML` max 512
    entries, `OF` max 256 entries, plus `prev` tables for `Repeat_Mode`),
    Huffman decode table (`1 << 11 = 2048` entries), a 128 KiB literals buffer
    (`ubyte[131_072]`), a sequence array buffer, `rep[3]`, and a rolling window
    buffer sized to the frame's `Window_Size`.
- **Encoder Workspace (`ZstdEncoderWorkspace`)**:
  - Allocated once per worker thread in `scheduler.d` (or once in single-thread
    mode) and reused across all 128 KiB blocks and frames.
  - Contains hash/chain tables, literal scratch buffer (`128 KiB`), sequence
    scratch buffer (max `131_072 / 3 = 43_691` sequences), symbol histograms,
    and FSE/Huffman build tables.

---

## 5. Detailed Component Specifications

### 5.1 XXH64 Checksum (`checksum.d`)

RFC 8878 §3.1.1 specifies that when `Content_Checksum_flag` is set, the frame
trailer carries the low-order 32 bits of an **XXH64** hash of the uncompressed
frame payload computed with `seed = 0`, stored in little-endian byte order.

- **Constants**:
  - `PRIME64_1 = 0x9E3779B185EBCA87UL`
  - `PRIME64_2 = 0xC2B2AE3D27D4EB4FUL`
  - `PRIME64_3 = 0x165667B19E3779F9UL`
  - `PRIME64_4 = 0x85EBCA77C2B2AE63UL`
  - `PRIME64_5 = 0x27D4EB2F165667C5UL`
- **API**:
  ```d
  struct Xxh64
  {
      void reset(ulong seed = 0) pure nothrow @nogc @safe;
      void put(scope const(ubyte)[] data) pure nothrow @nogc @safe;
      ulong finish() const pure nothrow @nogc @safe;
      uint finishLow32() const pure nothrow @nogc @safe;
  }

  ulong xxh64(scope const(ubyte)[] data, ulong seed = 0) pure nothrow @nogc @safe;
  uint  xxh64Low32(scope const(ubyte)[] data, ulong seed = 0) pure nothrow @nogc @safe;
  ```
- **Implementation**:
  - Streaming 32-byte stripe accumulator (`v1, v2, v3, v4`) with internal
    32-byte tail buffer `ubyte[32]` so arbitrary chunk boundaries produce
    identical hashes to one-shot `xxh64`.
  - Pure `@safe nothrow @nogc` using shift/add/multiply/rotl64 helper functions.

### 5.2 Backward Bitstreams (`zstd_bitstream.d`)

Both ZSTD Huffman streams and ZSTD FSE sequence streams are **backward
bitstreams**:

- **Format**:
  - A backward bitstream occupies a slice `src[0 .. N]`.
  - The last byte `src[N - 1]` must be non-zero (if `0`, return
    `ErrorKind.corruptInput`).
  - Its highest set bit (`7 - leadingZeros(src[N - 1])`) is the **padding
    sentinel bit** marking where the bitstream begins.
  - Bits are read from the MSB side downward toward `src[0]` (or accumulated in
    a 64-bit register filled from `src` backward).
- **`ZstdBackBitReader`**:
  - `static Result!ZstdBackBitReader init(return scope const(ubyte)[] slice)`
    locates and strips the sentinel bit in `slice[$ - 1]`.
  - `uint peekBits(uint nBits)` and `void consumeBits(uint nBits)` / `bool readBits(uint nBits, out uint val)`.
  - `bool isFinished()` verifies that all bytes down to `slice[0]` and all bits
    have been consumed (detecting over-read or under-read corruption per
    RFC 8878).
- **`ZstdBackBitWriter`**:
  - Appends bits in forward order into a byte buffer, and on `finish()` writes
    the final `1` sentinel bit and flushes remaining bits to a byte boundary.
  - Because a decoder reads bits in reverse order of how the encoder finished
    writing them, the encoder encodes sequences/literals in **reverse order**
    (from last sequence/literal to first), flushing state bits and finishing
    with the initial state bits and sentinel `1` bit.

### 5.3 Code Tables (`zstd_tables.d`)

Provides `@safe pure nothrow @nogc` `immutable` lookup tables defined in
RFC 8878 §3.1.1.3.2.1 and §3.1.1.4:

1. **Literals Length (`LL`) Codes `0..35`**:
   - Codes `0..15`: baseline `0..15`, `0` extra bits.
   - Codes `16..35`: baseline up to `65536`, extra bits `1..16`.
   - Default predefined distribution (64 states, `Accuracy_Log = 6`).
2. **Match Length (`ML`) Codes `0..52`**:
   - Codes `0..31`: baseline `3..34`, `0` extra bits.
   - Codes `32..52`: baseline up to `65539`, extra bits `1..16`.
   - Default predefined distribution (64 states, `Accuracy_Log = 6`).
3. **Offsets (`OF`) Codes `0..31`**:
   - Code `N` has `N` extra bits and baseline `1 << N`.
   - Default predefined distribution (`0..28`, 32 states, `Accuracy_Log = 5`).
4. **Reverse Mapping Helpers (Encoder)**:
   - `uint llCode(uint litLength)`
   - `uint mlCode(uint matchLength)` // `matchLength >= 3`
   - `uint ofCode(uint offsetValue)` // `bsr(offsetValue)`

### 5.4 Finite State Entropy (`zstd_fse.d`)

Implements tANS table parsing, building, decoding, and encoding:

1. **FSE Header Parsing (`readFseTableDescription`)**:
   - Reads `Accuracy_Log = (first4Bits) + 5` from a **forward** LSB bit reader.
   - Enforces max accuracy log (`9` for LL/ML, `8` for OF, `6` for Huffman
     weights).
   - Reads variable-length probability counts until `remaining == 0`.
   - Value `0` encodes `-1` ("less than 1" probability, occupying 1 state at
     the high end of the table and resetting with full `Accuracy_Log` bits).
   - Handles repeat-zero runs (2-bit counts of `3` repeated while `count == 3`).
2. **FSE Decoding Table (`FseDecodeTable`)**:
   ```d
   struct FseDecodeEntry
   {
       ubyte  symbol;
       ubyte  numBits;
       ushort newStateBase;
   }
   ```
   - Built deterministically using ZSTD's state spread step:
     `step = (tableSize >> 1) + (tableSize >> 3) + 3`, `mask = tableSize - 1`.
   - For each symbol with probability $> 0$, computes `numBits` and
     `newStateBase` in a single pass.
   - Validates that the sum of allocated states equals `1 << accuracyLog`
      exactly; otherwise returns `ErrorKind.corruptInput`.
3. **FSE Normalization & Encoding Table (`FseEncodeTable`)**:
   - Normalizes raw symbol histograms to `1 << accuracyLog` total weight while
     assigning `-1` (1 state) or `>= 1` to every symbol with count $> 0$.
   - Serializes the FSE table header for `FSE_Compressed_Mode`.
   - Encodes symbol transitions in reverse sequence order into
     `ZstdBackBitWriter`.

### 5.5 ZSTD Huffman (`zstd_huffman.d`)

ZSTD uses canonical Huffman codes with maximum code length **11 bits** for
literals (`0..255`) and **7 bits** for FSE-compressed Huffman weights (`0..12`):

1. **Weight Representation**:
   - `Weight == 0`: symbol not present.
   - `Weight > 0`: `Number_of_Bits = Max_Number_of_Bits + 1 - Weight`.
   - The last symbol's weight is omitted from the header and deduced via the
     Kraft sum power-of-two remainder (`totalWeight` must round up to the next
     power of two $\le 2^{11}$; otherwise reject as `ErrorKind.corruptInput`).
2. **Tree Header Deserialization / Serialization**:
   - `headerByte < 128`: `headerByte` bytes of FSE-compressed weights (decoded
     via two interleaved FSE states sharing one table with `Accuracy_Log <= 6`).
   - `headerByte >= 128`: `numSymbols = headerByte - 127` weights packed as
     4-bit nibbles (2 weights per byte, high nibble first).
3. **1-Stream and 4-Stream Decoding**:
   - Single lookup table of size `1 << maxBits` (up to `2048` entries of
     `(ubyte symbol, ubyte numBits)`).
   - **1-stream**: single `ZstdBackBitReader` over the compressed payload.
   - **4-stream**: reads 6-byte little-endian jump table
     (`uint16 stream1Size, stream2Size, stream3Size`), derives
     `stream4Size = totalSize - 6 - stream1Size - stream2Size - stream3Size`,
     validates bounds, and decodes the 4 independent backward bitstreams into 4
     contiguous quarters of `regeneratedSize` (first 3 quarters of size
     `(regeneratedSize + 3) / 4`, 4th quarter holds the remainder).
4. **1-Stream and 4-Stream Encoding**:
   - Builds length-limited Huffman tree capped at 11 bits (reusing package-merge
     or Kraft length-limiting logic adapted from [`huffman.d`](file:///home/leonardo/Projetos/zipd/packages/compressor/source/zipd/compressor/huffman.d)).
   - Emits direct 4-bit weight header (or FSE-compressed weight header when
     smaller) and encodes literals in 1-stream (when `< 256` literals) or
     4-stream (when $\ge 256$ literals, per RFC 8878).
   - Evaluates whether `Raw_Literals_Block` or `RLE_Literals_Block` is smaller
     than `Compressed_Literals_Block` and picks the smallest representation.

### 5.6 Sequence Decoding and Execution (`zstd_sequences.d`)

```d
struct ZstdSequence
{
    uint litLength;
    uint matchLength;
    uint offset; // Resolved actual back-reference distance (>= 1)
}
```

- **Sequence Bitstream Decoding**:
  1. Initialize `ZstdBackBitReader` over the remaining bytes of the block.
  2. Read initial states: `llState` (`llTable.accuracyLog` bits), `ofState`
     (`ofTable.accuracyLog` bits), `mlState` (`mlTable.accuracyLog` bits).
  3. For each of the `numSequences` sequences:
     - Look up `ofCode = ofTable[ofState].symbol`, `mlCode = mlTable[mlState].symbol`,
       `llCode = llTable[llState].symbol`.
     - Read extra bits in exact RFC 8878 order:
       1. `ofExtra` (`ofCode` bits) $\to$ `offsetValue = (1u << ofCode) + ofExtra`
       2. `mlExtra` (`mlExtraBits[mlCode]` bits) $\to$ `matchLength = mlBase[mlCode] + mlExtra`
       3. `llExtra` (`llExtraBits[llCode]` bits) $\to$ `litLength = llBase[llCode] + llExtra`
     - Resolve `offset` against `rep[0..3]` and update `rep[0..3]`.
     - If not the last sequence (`seqIdx + 1 < numSequences`), update FSE states
       in exact RFC 8878 order:
       1. Update `llState` (`llTable[llState].numBits` bits)
       2. Update `mlState` (`mlTable[mlState].numBits` bits)
       3. Update `ofState` (`ofTable[ofState].numBits` bits)
  4. Verify that the backward bitstream has reached the exact beginning of the
     slice (`reader.isFinished()`); otherwise return `ErrorKind.corruptInput`.

### 5.7 ZSTD Decoder (`zstd_frame.d` & `zstd_dec.d`)

- **Frame & Block Parser (`zstd_frame.d`)**:
  - `bool isZstdMagic(scope const(ubyte)[] data)` (`0xFD2FB528` or skippable `0x184D2A5?`).
  - `Result!ZstdFrameHeader parseZstdFrameHeader(scope const(ubyte)[] src)`
  - `Result!ZstdBlockHeader parseZstdBlockHeader(scope const(ubyte)[] src)`
- **Full Decoder (`zstd_dec.d`)**:
  - Maintains sliding window buffer up to `Window_Size` so back-references can
    reach across blocks within a frame.
  - Maintains `rep[3]`, `prevHuffmanTable`, and `prevFseTables[3]` across blocks
    within a frame, resetting them at every new frame boundary.
  - Accumulates uncompressed bytes into `Xxh64` when `Content_Checksum_flag` is
    set, and verifies the 4-byte checksum at the end of the frame (returning
    `ErrorKind.checksum` on mismatch).
  - Verifies that total decoded bytes match `Frame_Content_Size` when declared
    in the header (returning `ErrorKind.corruptInput` on mismatch).

### 5.8 ZSTD Match Finder and Encoder (`zstd_lz.d` & `zstd_enc.d`)

1. **Level Table (`1..9`)**:
   | Level | Strategy | Window Size | Hash Log | Chain Depth | Notes |
   |---:|---|---:|---:|---:|---|
   | 1 | Fast hash table + `rep[0]` probe | 128 KiB | 14 | 1 | Fastest, direct hash lookup |
   | 2 | Fast hash table + `rep[0..2]` probes | 256 KiB | 15 | 2 | Short chain + repeat offsets |
   | 3 | Greedy hash chain + `rep[0..2]` | 512 KiB | 16 | 8 | Default fast mode |
   | 4 | Lazy match + `rep[0..2]` | 1 MiB | 16 | 16 | 1-step lazy evaluation |
   | 5 | Lazy match + `rep[0..2]` | 2 MiB | 17 | 32 | Balanced ratio/speed |
   | 6 | Lazy match + `rep[0..2]` + dynamic FSE | 4 MiB | 17 | 64 | Default `zipd` level |
   | 7 | Deep lazy + dynamic FSE + 4-stream Huff | 4 MiB | 18 | 128 | High ratio |
   | 8 | Deep lazy + dynamic FSE + 4-stream Huff | 8 MiB | 18 | 512 | High ratio |
   | 9 | Max chain + dynamic FSE + 4-stream Huff | 8 MiB | 18 | 2048 | Maximum effort |

2. **Repeat-Offset Aware Matching (`zstd_lz.d`)**:
   - Before walking the hash chain at position `pos`, the matcher checks if
     `rep[0]` (or `rep[1]`, `rep[2]`) produces a match of length $\ge 3$ (or
     $\ge 4$ for 4-byte hashes). Because repeat-offset codes `0..2` require zero
     or minimal extra bits, a repeat match of length $L$ beats a non-repeat
     match of length $L + 1$.
   - The encoder maintains the exact same `rep[0..3]` state transitions during
     match emission as the decoder does during sequence execution, ensuring
     emitted `offsetValue` codes (`1..3` vs `offset + 3`) stay in lockstep.

3. **Block Type & Mode Selection (`zstd_enc.d`)**:
   - Input is partitioned into blocks of at most 128 KiB (`131_072` bytes).
   - If `--store` (`CompressMode.store`) is requested, emits `Raw_Block`s only.
   - If all bytes in a block are identical, emits a 1-byte `RLE_Block`.
   - Otherwise collects literals and raw sequences `(litLen, matchLen, offsetValue)`:
     - Encodes literals using the smallest of `Raw_Literals_Block`,
       `RLE_Literals_Block`, or `Compressed_Literals_Block`.
     - For each of `LL`, `OF`, and `ML`, selects `RLE_Mode` if only 1 distinct
       symbol code occurs, or chooses between `Predefined_Mode` and
       `FSE_Compressed_Mode` based on estimated bit cost.
     - Packs the sequences in **reverse order** into `ZstdBackBitWriter`.
     - **Incompressible Fallback**: If the resulting `Compressed_Block` payload
       is $\ge$ the uncompressed block length, falls back to emitting a
       `Raw_Block` and rolls back the frame's `rep[0..3]` / table state to the
       pre-block snapshot so the decoder stays synchronized.

---

## 6. Public API, Multicore, and CLI Integration

### 6.1 `zipd.compressor.settings` Updates

```d
enum CodecId : ubyte
{
    deflate = 1,
    lzma2   = 2, // reserved
    zstd    = 3,
}

enum ContainerKind : ubyte
{
    gzip       = 1,
    rawDeflate = 2,
    zlib       = 3,
    zstd       = 4,
}
```

- When `codec == CodecId.zstd`, `normalize()` defaults `container` to
  `ContainerKind.zstd` (and vice versa).
- `CompressionSettings` remains backward-compatible (`deflate` + `gzip` is still
  the default unless `--codec zstd` or a `.zst` output extension is specified).

### 6.2 Format Auto-Detection in `streaming.d` and `commands.d`

1. **`compressFile`**:
   - Dispatches on `settings.container`:
     - `ContainerKind.gzip`: existing single-member or `compressMultiMember`
       path.
     - `ContainerKind.zstd`: single-frame ZSTD encoder when `effectiveThreads == 1`,
       or multi-frame `compressMultiMember` when `effectiveThreads > 1`.
2. **`decompressFile` / `test` / `info`**:
   - Peeks the first 4 bytes of the input stream:
     - `1F 8B`: dispatches to the existing gzip decoder / inspector.
     - `28 B5 2F FD` or `50..5F 2A 4D 18`: dispatches to the ZSTD frame
       decoder / inspector.
     - Anything else: returns `ErrorKind.unsupported` or `ErrorKind.corruptInput`.
   - `zipd info <file.zst>` reports frame count, window size, content size (if
     present), checksum presence, and block count.

### 6.3 CLI Options (`args.d`)

Add `--codec <deflate|gzip|zstd>` (and optional auto-selection when the `-o`
filename ends with `.zst` and `--codec` was not explicitly passed):

```text
zipd compress   input.tar -o input.tar.zst --codec zstd --level 6 --threads 4
zipd decompress input.tar.zst -o input.tar
zipd test       input.tar.zst
zipd info       input.tar.zst
```

---

## 7. Phased Implementation Roadmap

### Phase 1 — Primitives: XXH64, Backward Bitstream, and RFC 8878 Tables

> **Status: complete.** Implementation notes: XXH64 lives in its own module
> `xxhash.d` (not `checksum.d`); `zstd_tables.d`, `zstd_bitstream.d` and
> `zstd_frame.d` are as specified. All unit tests pass and a real
> `zstd -c` frame is cross-checked in `zstd_frame.d`.

**Deliverables**:
1. `Xxh64` streaming and one-shot implementation in `checksum.d` with RFC/known
   test vectors.
2. `zstd_bitstream.d` (`ZstdBackBitReader` and `ZstdBackBitWriter`) with unit
   tests for sentinel bit handling, odd bit widths (`1..24` bits), and exact
   consumption checks.
3. `zstd_tables.d` containing `LL`, `ML`, `OF` baseline/extra-bit tables,
   reverse code lookup functions, and predefined FSE normalized distributions.
4. `zstd_frame.d` frame header, block header, skippable frame, and checksum
   trailer parser/writer.

**Exit Criteria**:
- `dub test :compressor --config=unittest` passes all new unit tests.
- CI safety grep passes (`0` `@system`, `0` `@trusted` outside `unsafe.d`).

### Phase 2 — ZSTD Frame Decoder + `Raw`/`RLE` Encoder

> **Status: complete.** Decoder verified against stock `zstd` levels 1/3/9/19
> and `--ultra -22`; encoder output decodes with stock `zstd -d`.

**Deliverables**:
1. `zstd_fse.d` FSE table decoding, predefined table initialization, and state
   machine transitions.
2. `zstd_huffman.d` 1-stream and 4-stream Huffman literal decoding (both
   FSE-compressed weights and direct 4-bit weights, plus `Treeless` repeat mode).
3. `zstd_sequences.d` sequence bitstream decoder, `rep[0..3]` state machine, and
   sliding-window match execution.
4. `zstd_dec.d` full ZSTD frame and concatenated multi-frame decoder.
5. Initial `zstd_enc.d` supporting `Raw_Block` (`--store`) and `RLE_Block`
   emission with XXH64 content checksums.
6. Wire `--codec zstd` and magic-byte auto-detection into `settings.d`,
   `streaming.d`, `args.d`, and `commands.d`.

**Exit Criteria**:
- `zipd decompress` successfully decodes files compressed by stock `zstd -1`,
  `zstd -3`, `zstd -9`, `zstd -19`, and `zstd --ultra -22` (within window cap).
- `zipd compress --codec zstd --store` output is decompressed by stock
  `zstd -d` and `unzstd`.
- Skippable frames and concatenated frames produced by `zstd` decode cleanly.
- Corrupt frame headers, bad block sizes, invalid offsets, and bad XXH64
  checksums fail with typed `ErrorKind.corruptInput` or `ErrorKind.checksum`.

### Phase 3 — Full ZSTD Compressed-Block Encoder

> **Status: complete.** Implemented `zstd_sequences.d` (lockstep repeat offsets),
> `zstd_fse_enc.d` (FSE normalization, table header, compression table, per-symbol encoding),
> `zstd_huffman_enc.d` (canonical 11-bit code, FSE/direct weight header, 1/4-stream encode),
> `zstd_lz.d` (hash chain matcher with repeat-offset probing and lazy evaluation across levels 1..9),
> and integrated into `zstd_enc.d` with automatic fallback on incompressible blocks.
> Full bidirectional roundtrip verified against stock `zstd` across levels 1..9,
> achieving < 0.02% size on 1 MiB redundant text input (130 bytes).

**Deliverables**:
1. `zstd_lz.d` hash-chain match finder with repeat-offset probing (`rep[0..2]`)
   and lazy matching for levels `1..9`.
2. Sequence emission in `zstd_enc.d` using `Predefined_Mode` and `RLE_Mode`
   first, with automatic fallback to `Raw_Block` on incompressible chunks.
3. Dynamic FSE table normalization and header emission (`FSE_Compressed_Mode`)
   plus `Repeat_Mode` across blocks in `zstd_fse.d` / `zstd_enc.d`.
4. Dynamic 1-stream and 4-stream Huffman literal compression in
   `zstd_huffman.d` / `zstd_enc.d`.

**Exit Criteria**:
- Bidirectional round-trip (`zipd -> zstd -d` and `zstd -> zipd decompress`)
  passes across levels `1..9` on empty, small, repetitive text, random binary,
  and multi-megabyte inputs.
- Redundant 1 MiB text compresses to `< 5%` of original size with `--codec zstd`.

### Phase 4 — Multicore ZSTD Frames, Benchmarking, and Polish

> **Status: complete.** Extended `scheduler.d` to emit concatenated independent ZSTD frames
> with per-worker thread pools and bounded queues. Extended `streaming.d` to dispatch
> multi-frame ZSTD streams when `--threads > 1` (or auto `0`). Extended `tools/interop-test.sh`
> with multicore roundtrip and determinism checks against stock `zstd -d`.
> Extended `tools/benchmark.sh` to support `BENCHMARK_CODEC=zstd`.
> All 25 modules passed unittests and strict `@safe` safety grep.

**Deliverables**:
1. Extend `scheduler.d` (`encodeMember` / `compressMultiMember`) to encode
   independent ZSTD frames when `settings.container == ContainerKind.zstd`,
   reusing per-worker encoder workspaces.
2. Update `tests/compose.yml` to install `zstd` alongside `gzip` and extend
   `tools/interop-test.sh` with a complete ZSTD test matrix (single-thread,
   multi-thread, determinism, ratio check, corruption tests).
3. Extend `tools/benchmark.sh` to benchmark both `deflate` and `zstd` across
   thread counts.

**Exit Criteria**:
- `--codec zstd --threads 1|2|4|0` produces deterministic, valid concatenated
  ZSTD frames that decompress cleanly with both `zstd -d` and `zipd decompress`.
- Container validation (`podman compose -f tests/compose.yml run --rm test-safe-d`)
  passes all unit, safety, and interop tests.

---

## 8. Verification and Test Matrix

### 8.1 Unit Tests (`dub test :compressor --config=unittest`)

1. **XXH64**: Empty input (`0xEF46DB3751D8E999`), 1-byte, 31-byte, 32-byte,
   33-byte, and multi-chunk streaming vs one-shot equivalence.
2. **Backward Bitstream**: Round-trip encoding/decoding of mixed bit lengths
   (`1..24` bits) and detection of zero trailing byte or unconsumed bits.
3. **FSE**: Predefined LL/ML/OF table construction, normalized histogram sum
   invariants, and reverse-encode / forward-decode sequence round trips.
4. **Huffman**: 11-bit code-length limiting, direct nibble and FSE-compressed
   weight headers, 1-stream and 4-stream literal round trips, and `Treeless`
   reuse.
5. **Repeat Offsets**: Unit tests covering all special cases (`offsetValue`
   `1..3` with `litLength > 0` vs `litLength == 0`, including `rep[0] - 1`).
6. **Negative / Corruption Suite**:
   - Bad magic number.
   - Non-zero `Reserved_bit` in `Frame_Header_Descriptor`.
   - `Window_Size` exceeding configured decoder safety limit.
   - `Block_Type == 3` (`Reserved`).
   - `Block_Size > 128 KiB`.
   - Sequence `offset > totalProduced` or `offset > Window_Size` or `rep[0] - 1 == 0`.
   - Huffman Kraft sum overflow (`> 2^11`) or incomplete tree.
   - FSE probability sum $\ne 2^{\text{Accuracy\_Log}}$.
   - Truncated block or trailing unconsumed bits in sequence bitstream.
   - Corrupted XXH64 content checksum (`ErrorKind.checksum`).
   - Mismatched `Frame_Content_Size` (`ErrorKind.corruptInput`).

### 8.2 Interop Matrix (`tools/interop-test.sh`)

For fixtures `empty`, `small`, `repeat`, `binary`, `bigtext`, and `mt.in`:

```bash
# 1. zipd (zstd) -> stock zstd -d
zipd compress "$in" -o "$zst" --codec zstd --level "$lvl" --quiet
zstd -d -c "$zst" > "$out"
cmp -s "$in" "$out"

# 2. stock zstd -> zipd decompress
zstd -"$lvl" -c "$in" > "$zst"
zipd decompress "$zst" -o "$out" --quiet
cmp -s "$in" "$out"

# 3. Multi-threaded determinism & interop
zipd compress "$mt_in" -o "$mt_a" --codec zstd --threads 4 --chunk-size 256k --quiet
zipd compress "$mt_in" -o "$mt_b" --codec zstd --threads 4 --chunk-size 256k --quiet
cmp -s "$mt_a" "$mt_b"
zstd -d -c "$mt_a" | cmp -s - "$mt_in"
```

---

## 9. Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---:|---|
| Off-by-one bit errors in backward bitstreams (FSE & Huffman) | High | Implement `zstd_bitstream.d` first with exhaustive round-trip unit tests and RFC 8878 byte-level test vectors before wiring into FSE/Huffman. |
| Repeat-offset state desynchronization between encoder and decoder when `litLength == 0` | High | Centralize the `updateRepOffsets` state transition function in `zstd_sequences.d` and call the exact same function from both encoder and decoder. |
| Incompressible block expansion or state corruption on fallback to `Raw_Block` | Medium | Save a lightweight snapshot of `(rep[0..3], prevHuffman, prevFse)` before encoding each block; restore snapshot whenever falling back to `Raw_Block` or `RLE_Block`. |
| Memory growth from large `Window_Descriptor` values in untrusted inputs | Medium | Cap decoder window allocation at `min(Window_Size, maxAllowedWindow)` (default 128 MiB) and cap single-frame output when `Single_Segment_flag` is set. |
| GC allocations inside worker loops degrading multicore throughput | Medium | Pre-allocate `ZstdEncoderWorkspace` per worker slot in `scheduler.d` and keep inner block encoding `@nogc`. |
