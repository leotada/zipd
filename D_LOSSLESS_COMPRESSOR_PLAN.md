# Plan - @safe D Lossless Compressor CLI (DEFLATE-first)

This document plans a new lossless compressor written in high-level D. The
target is a production-ready command line tool for compression and
decompression, with all project-owned hot-path code in the compressor and CLI
compiling as `@safe`, with `-preview=dip1000` enabled, and with multicore
compression as a first-class design goal.

This plan is explicitly **additive**. The new compressor must be written in a
new directory tree and must not replace, rewrite in place, or destabilize the
existing D port or existing C/C++ source trees. Existing code remains as
reference, baseline, and compatibility material while the new compressor is
developed alongside it.

The chosen first codec is **DEFLATE** (RFC 1951), wrapped in **gzip** frames
(RFC 1952). DEFLATE was selected over LZMA2 and ZSTD after a review of
implementation effort vs. shippable value:

1. DEFLATE has no range coder and no precomputed price tables; the encoder is
   roughly an order of magnitude smaller than an LZMA2 encoder.
2. The repository contains no DEFLATE *encoder*, but the algorithm is fully
   specified by RFC 1951 and well covered by reference implementations
   (`puff.c`, `miniz`, `libdeflate`) — unlike ZSTD, where the encoder
   (FSE/ANS, repcode model, block splitter) is far larger than LZMA2.
3. DEFLATE blocks are naturally independent (each block carries its own
   Huffman tables), which maps cleanly to a multicore block scheduler with
   no ratio cost beyond what `pigz` already accepts.
4. Wrapping output in **gzip** gives instant interoperability with every
   standard tool (`gunzip`, `zcat`, libraries everywhere) and removes the
   need to design, debug, and version a custom container for v1.
5. Concatenated gzip members are a standard feature handled by `gunzip`,
   so multicore output is a sequence of independent gzip members rather
   than a custom frame.

LZMA2 remains a planned **optional** high-ratio codec for a later phase, after
the safe DEFLATE pipeline, scheduler, CLI, and tests are stable. ZSTD and
Brotli are out of scope because their encoders are larger than LZMA2's.

---

## 1. Goals

1. Create a lossless compressor and decompressor in high-level D.
2. Keep all hot-path codec logic and the public API of the compressor and CLI
   `@safe`. Permit a single, named, audited `@trusted` shim module for I/O
   and threading primitives that cannot otherwise be expressed safely.
3. Compile new packages with `-preview=dip1000` from the beginning.
4. Use D slices, structs, ranges where useful, typed errors, and clear APIs
   instead of exposing C-style pointer APIs to the CLI layer.
5. Extract multicore performance through independent DEFLATE blocks emitted
   as concatenated gzip members.
6. Provide a usable CLI for compressing and decompressing files in a
   `gzip`-compatible container.
7. Keep performance competitive by using LDC release builds, reusable buffers,
   bounded queues, per-worker encoder state, and minimal allocation inside
   hot paths.
8. Add validation for round trips, corruption handling, safety annotations,
   thread scaling, memory use, and interoperability with stock `gunzip`.

---

## 2. Non-goals For The First Release

1. Do not implement a full `.7z` archive writer in the first release.
2. Do not support multiple files, directories, permissions, timestamps, or
   solid archives in the first release.
3. Do not implement LZMA2, ZSTD, Brotli, or bzip2 in the first release.
   LZMA2 is a planned later codec; ZSTD/Brotli/bzip2 are out of scope.
4. Do not rely on widespread project-owned `@trusted` to claim safety. A
   single, audited, file-scoped shim module is permitted; everywhere else
   `@trusted` is forbidden and enforced by CI grep.
5. Do not optimize with assembly or unsafe pointer tricks in the first
   release. Later phases can evaluate SIMD or external optimized kernels
   behind a separate safety review.
6. Do not replace existing code in `sevenzip-d/packages/core`, `C/`, or
   `CPP/`. The new compressor must live in a new directory structure and
   integrate by addition, not by invasive replacement.
7. Do not design a custom container format for v1. Output is standard
   gzip (RFC 1952), single-member or concatenated.

---

## 3. Codec Decision: DEFLATE First

### 3.1 Why DEFLATE

1. Encoder size: roughly 1–2k lines of D for a competent implementation,
   versus ~8–10k lines for a full LZMA2 encoder (LzFind + range coder +
   optimal parser + LZMA2 framing) and even more for ZSTD.
2. No range coder. Huffman + LZ77 are straightforward to implement safely.
3. Match finder can be a hash chain at level ≤ 6; binary trees are not
   required. LZMA2 effectively requires BT4 to be useful.
4. Block independence is native — every DEFLATE block carries its own
   Huffman tables, so chunking for multicore is lossless on ratio in the
   way `pigz` already proves.
5. No shared encoder state across blocks, no inter-chunk dictionary carry,
   no giant precomputed price tables. Maps cleanly to `@safe` + DIP1000.
6. Output container (gzip) is universally interoperable.

### 3.2 Why Not ZSTD / Brotli

1. ZSTD encoder (FSE/ANS, repcode model, block splitter, optional
   dictionary trainer) is larger and more intricate than LZMA2.
2. Brotli encoder is larger than ZSTD and depends on a static dictionary.
3. The repository contains a ZSTD decoder but no encoder, and no Brotli
   code at all. Either would mean writing a major encoder from scratch
   while also building the rest of the project.

### 3.3 Why Not LZMA2 First (Deferred, Not Cancelled)

1. Highest ratio in this family, but the encoder is the largest single
   work item in the project.
2. Independent blocks cost meaningful ratio for LZMA2, unlike DEFLATE.
3. Better introduced after the safe pipeline, scheduler, and CLI are
   green, so the LZMA2 port is the *only* unknown when it lands.

### 3.4 Decision

Use DEFLATE (RFC 1951) wrapped in gzip (RFC 1952) for the first release.
Keep the public codec interface generic so LZMA2 can be added later behind
`--codec lzma2` without changing the CLI shape.

---

## 4. Proposed Directory And Package Layout

The new compressor lives in a dedicated package layout at the repository
root so it stays clearly separated from the existing `sevenzip-d` port.

Recommended structure:

```text
.
|-- dub.sdl
|-- packages/
|   |-- compressor/
|   |   |-- dub.sdl
|   |   `-- source/sevenzip/compressor/
|   |       |-- package.d
|   |       |-- errors.d
|   |       |-- settings.d
|   |       |-- checksum.d        // CRC32, Adler32
|   |       |-- bitwriter.d
|   |       |-- huffman.d
|   |       |-- lz77.d            // hash-chain match finder
|   |       |-- deflate_enc.d
|   |       |-- deflate_dec.d
|   |       |-- gzip.d            // RFC 1952 framing
|   |       |-- codec.d           // generic codec iface
|   |       |-- scheduler.d
|   |       |-- streaming.d
|   |       `-- unsafe.d          // ONLY @trusted shim
|   `-- compress-cli/
|       |-- dub.sdl
|       `-- source/sevenzip/cli/
|           |-- args.d
|           |-- commands.d
|           |-- io.d
|           `-- exitcode.d
|-- tests/
|   |-- compose.yml
|   `-- fixtures/
|-- tools/
|   |-- gen-fixtures.sh
|   `-- compare-bin.sh
`-- docs/
    |-- format.md
    `-- benchmark-notes.md
```

The new project may read ideas, constants, and test vectors from the current
port and from the `C/` tree, but its source files remain physically separated.
Do not add the new packages under the existing `sevenzip-d/packages/` tree.

Workspace `dub.sdl`:

```sdl
name "zipd"
description "Safe high-level D lossless compressor workspace (DEFLATE first)"
targetType "none"

subPackage "packages/compressor"
subPackage "packages/compress-cli"
```

Roles:

1. `compressor` owns the safe DEFLATE encoder/decoder, gzip framing,
   codec abstraction, scheduler, and reusable library API.
2. `compress-cli` owns argument parsing, file I/O, terminal output, and
   exit codes.
3. `unsafe.d` is the **only** module permitted to use `@trusted`, and is
   restricted to thin wrappers over `std.stdio` raw I/O and thread
   primitives. CI enforces this.

---

## 5. Safety Model

### 5.1 Required Compiler Flags

Every new package compiles with DIP1000:

```sdl
dflags "-preview=dip1000"
```

Release and test builds use the same DIP1000 setting.

### 5.2 Module Defaults

Every project-owned compressor module begins with:

```d
module sevenzip.compressor.example;

@safe:
```

Hot-path functions are additionally `nothrow` and `@nogc` where practical,
but `@safe` is the non-negotiable requirement.

### 5.3 DIP1000 API Style

Use scoped slices for buffers that do not escape:

```d
size_t encodeBlock(scope const(ubyte)[] input,
                   scope ubyte[] output) @safe;
```

Use `return scope` only when returning a view into caller-owned memory.

Rules:

1. Mark every non-escaping slice parameter as `scope`.
2. Do not store scoped input slices in long-lived structs.
3. Do not return references to stack buffers.
4. Prefer value structs for metadata.
5. Prefer owned `ubyte[]` for compressed blocks crossing thread boundaries.

### 5.4 Safety Boundary

The release target enforces, via CI, that the only file containing
`@trusted` in the new packages is
`packages/compressor/source/sevenzip/compressor/unsafe.d`:

```bash
# Must succeed (no @trusted outside the audited shim).
! grep -RE '\b@trusted\b' \
    packages/compressor packages/compress-cli \
  | grep -v 'compressor/unsafe.d'

# Must succeed (no @system anywhere in project-owned new code).
! grep -RE '\b@system\b' \
    packages/compressor packages/compress-cli
```

`unsafe.d` contents are restricted to:

1. Wrappers over `File.rawRead` / `File.rawWrite`.
2. Wrappers over `core.thread.Thread` and `core.sync.*` primitives.
3. Nothing else. No pointer arithmetic. No casts that strip `const`.
   No GC tricks.

Every wrapper in `unsafe.d` carries a comment explaining why the
wrapped operation cannot be expressed in `@safe` D today. If a future
Phobos/druntime release makes any of those operations genuinely `@safe`,
the corresponding wrapper is deleted.

---

## 6. File Format For Version 1

The first release emits **standard gzip** (RFC 1952). No custom container.

### 6.1 Single-threaded Output

A single gzip member containing one or more DEFLATE blocks, exactly as a
conventional `gzip` would emit. Trailer carries CRC32 and ISIZE
(uncompressed size mod 2^32).

### 6.2 Multi-threaded Output

A sequence of **concatenated gzip members**, one per input chunk:

```text
[ gzip member 0 | gzip member 1 | gzip member 2 | ... ]
```

Each member is a complete RFC 1952 stream over its own input chunk.
Stock `gunzip`, `zcat`, and `zlib`-based readers handle this natively
(it is the same scheme `pigz` uses).

### 6.3 Why This Choice

1. Zero custom format work in v1.
2. Output is decompressible by every standard tool.
3. Multicore is just "emit members in input order" — no shared header,
   no global table.
4. Per-member CRC32 + ISIZE provides per-chunk integrity automatically.
5. The compressor can later add a custom container only if a feature
   genuinely requires it (e.g., random access, parallel decode index).

### 6.4 Determinism

For the same input bytes, same `--level`, same `--threads`, same
`--chunk-size`, the output bytes must be identical across runs. This
requires:

1. Chunking is a pure function of input offset, not arrival order.
2. Per-block Huffman selection is deterministic (no wall-clock budgets).
3. Match finder tie-breaking is deterministic.
4. gzip header fields that vary by default (`MTIME`, `OS`, `FNAME`)
   are fixed: `MTIME=0`, `OS=255` (unknown), no `FNAME` unless the
   user passes `--name`.

### 6.5 Future Compatibility Formats

After the safe codec is stable, optional writers may be added:

1. Raw DEFLATE stream (no framing) for embedding.
2. zlib (RFC 1950) framing for protocol use.
3. `.xz` writer once the LZMA2 codec lands.
4. `.7z` writer after archive update support exists.

---

## 7. Public Library API

The compressor package exposes a high-level API independent of the CLI.

```d
module sevenzip.compressor;

@safe:

enum CodecId : ubyte
{
    deflate = 1,
    lzma2   = 2, // future
}

enum ContainerKind : ubyte
{
    gzip       = 1,
    rawDeflate = 2,
    zlib       = 3,
}

struct CompressionSettings
{
    CodecId codec = CodecId.deflate;
    ContainerKind container = ContainerKind.gzip;
    uint level = 6;                       // gzip-style 1..9
    uint threads = 0;                     // 0 = auto
    size_t chunkSize = 1 * 1024 * 1024;   // 1 MiB default per worker block
    bool storeName = false;               // include FNAME in gzip header
}

struct CompressionStats
{
    ulong inputBytes;
    ulong outputBytes;
    ulong blocks;
    double elapsedSeconds;
}

// Project-owned typed result; concrete shape decided in Phase 1.
// Sketch: a tagged union of (T value | ErrorInfo error).
struct Result(T) { /* ... */ }

Result!CompressionStats compressFile(
    scope const(char)[] inputPath,
    scope const(char)[] outputPath,
    CompressionSettings settings) @safe;

Result!CompressionStats decompressFile(
    scope const(char)[] inputPath,
    scope const(char)[] outputPath) @safe;
```

`Result!T` avoids throwing in hot paths. The CLI converts it to exit
codes and human-readable messages.

---

## 8. CLI Design

Suggested executable name: `dgz`.

### 8.1 Commands

```text
dgz compress   <input> -o <output>
dgz decompress <input> -o <output>
dgz test       <input>
dgz info       <input>
```

Short aliases:

```text
dgz c <input> -o <output>
dgz d <input> -o <output>
dgz t <input>
```

### 8.2 Options

```text
--level N          Compression level, 1..9, default 6
--threads N        Worker count, 0 means auto
--chunk-size SIZE  Independent block size, e.g. 256k, 1m, 4m
--stdout           Write output to stdout (mutually exclusive with -o)
--force            Overwrite output
--keep             Keep input after success (default: keep)
--name             Store original filename in gzip FNAME field
--quiet            Only print errors
--verbose          Print settings and timing
```

If both `--stdout` and `-o` are given, exit with code 2.

### 8.3 Behavior Details

1. **Atomic output.** Write to `<output>.tmp` then rename on success.
2. **Signal handling.** On SIGINT/SIGTERM during compression, delete the
   partial `<output>.tmp` and exit with code 1 unless `--keep-partial`
   is passed.
3. **Default keeps the input file.** Unlike `gzip(1)`, `dgz` never
   deletes the input. Document loudly.
4. **Decompression accepts concatenated gzip members** transparently.
5. `--verbose` prints normalized settings, including the actual
   `effectiveChunkSize` and `effectiveThreads`.

### 8.4 Exit Codes

```text
0  success
1  generic failure
2  invalid command line
3  input/output error
4  unsupported format or version
5  corrupt input
6  checksum mismatch
8  internal error
```

Exit code 7 from earlier drafts is removed — reliable OOM detection from
D is impractical; allocation failures fall under code 1 or 8.

---

## 9. Multicore Compression Architecture

### 9.1 Block Model

Input is split into independent chunks of `chunkSize` bytes. Each chunk
is compressed into its own complete gzip member by an independent worker
with its own encoder state. Output is the concatenation of members in
input order.

### 9.2 Worker Model

1. Reader reads chunks into owned buffers.
2. Scheduler submits chunks to workers with a bounded in-flight limit.
3. Each worker compresses one chunk into a complete gzip member.
4. Each worker computes the chunk's CRC32 and ISIZE for its trailer.
5. Results are returned as `(index, ownedMemberBytes)`.
6. The **main thread** is the writer; it emits members in increasing
   index order. Single writer, no second writer thread in v1.

No encoder state is shared between workers. This keeps the design `@safe`
and avoids synchronization in the hot path.

### 9.3 Bounded Memory

```text
peakMemory ~= threads * (chunkSize + outputBuffer + encoderWorkspace)
           + writerQueueLimit * averageCompressedChunk
```

For DEFLATE with a hash-chain match finder, `encoderWorkspace` is small
(hash table + 32 KiB sliding window + chain links), typically a few
hundred KiB per worker. Default `chunkSize=1 MiB` keeps total memory
modest even at high thread counts.

`writerQueueLimit` defaults to `threads * 2`.

### 9.4 D Concurrency Choice

Use a small project-owned bounded queue with `core.thread.Thread` and
`core.sync.condition.Condition`, wrapped via the `unsafe.d` shim.
`std.parallelism` is not used in v1 because its `@safe` story under
DIP1000 is fragile and its task/queue semantics complicate deterministic
ordering.

The queue interface is `@safe`. It only carries owned buffers and
plain-old-data metadata.

---

## 10. DEFLATE Implementation Plan

### 10.1 Encoder Components

1. **Bit writer** (`bitwriter.d`) — LSB-first bit packing into an output
   slice, with bounds checks; `@safe` and `@nogc`.
2. **Hash-chain match finder** (`lz77.d`) — 3-byte hash, configurable
   chain length per level. No binary trees in v1.
3. **Greedy + lazy matcher** (`lz77.d`) — greedy at low levels, lazy
   matching at levels ≥ 4. No optimal parser in v1.
4. **Huffman builder** (`huffman.d`) — package-merge or a length-limited
   Kraft construction capped at 15 bits for literal/length and 7 bits
   for distance, per RFC 1951.
5. **Block emitter** (`deflate_enc.d`) — choose between BTYPE=00
   (stored), BTYPE=01 (fixed Huffman), BTYPE=10 (dynamic Huffman) per
   block by estimated cost; emit one or more blocks per chunk and a
   final block with BFINAL=1.
6. **gzip framer** (`gzip.d`) — emit the 10-byte gzip header (with
   `MTIME=0`, `OS=255`), optional FNAME, the DEFLATE stream, then the
   8-byte trailer (CRC32, ISIZE).

### 10.2 Decoder Components

1. **Bit reader** (`deflate_dec.d`) — LSB-first.
2. **Huffman table builder** for canonical codes from code-length
   sequences.
3. **Block decoder** for BTYPE 00/01/10, with strict bounds checks on
   length/distance pairs against the sliding window.
4. **gzip parser** (`gzip.d`) — verify magic `1f 8b`, method `08`,
   parse flags (FTEXT/FHCRC/FEXTRA/FNAME/FCOMMENT), validate CRC32 and
   ISIZE on the trailer.
5. **Concatenated member loop** — after a member's trailer, attempt to
   parse another member; EOF after a complete member is success.

### 10.3 Level Mapping

Initial mapping (subject to tuning in Phase 4):

```text
level 1: chain=4,    max-lazy=0,   greedy
level 3: chain=16,   max-lazy=0,   greedy
level 6: chain=128,  max-lazy=16,  lazy        (default)
level 9: chain=4096, max-lazy=258, lazy
```

Window size is fixed at 32 KiB (RFC 1951 maximum). `--store` (or
`level 0` if exposed) emits BTYPE=00 blocks only.

### 10.4 First Usable Codec Milestone

Reached when these all pass:

1. Empty input round trips.
2. Small input round trips.
3. Highly repeated input round trips.
4. Random binary input round trips.
5. Multi-megabyte input round trips.
6. Output of `dgz compress` decompresses with stock `gunzip`.
7. Input produced by stock `gzip` decompresses with `dgz decompress`.
8. Concatenated gzip members produced by `pigz` decompress correctly.
9. Corrupt payload (flipped byte in the DEFLATE stream or trailer) is
   rejected with a typed error.
10. All public functions used by `packages/compress-cli` are `@safe`.

---

## 11. Performance Plan

### 11.1 Build Mode

Benchmark with LDC release builds:

```bash
dub build :compress-cli --build=release
```

### 11.2 Default Settings

```text
codec:      deflate
container:  gzip
level:      6
threads:    logical CPU count
chunkSize:  1 MiB
```

Reference targets at level 6 on a typical desktop CPU (single core):

```text
compression:    >= 30 MB/s on text
decompression:  >= 200 MB/s on text
ratio:          within 10% of stock gzip -6
```

These are stretch goals, not blocking acceptance criteria.

### 11.3 Metrics

Track for every benchmark:

1. Input size.
2. Output size.
3. Compression ratio.
4. Compression MB/s.
5. Decompression MB/s.
6. Elapsed wall time.
7. User CPU time.
8. Peak RSS.
9. Thread count.
10. Chunk size.

### 11.4 Benchmark Corpus

Place fixtures under the new project, generated by a script — not
checked in:

```text
tests/fixtures/bench/
   text-large.txt        (generated)
   json-large.json       (generated)
   binary-random.bin     (generated)
   binary-repeated.bin   (generated)
   source-tree.tar       (generated from sevenzip-d/)
   mixed-small-files.tar (generated)
```

`tools/gen-fixtures.sh` generates them on demand. CI generates a small
subset; benchmark runs generate the larger ones locally.

---

## 12. Test Plan

### 12.1 Unit Tests

1. Settings normalization.
2. CLI size parsing such as `256k`, `1m`, `4m`.
3. CRC32 against known vectors.
4. Bit writer / bit reader round trip.
5. Huffman code construction with length limit.
6. gzip header encode/decode (including FNAME).
7. Result/error conversion.
8. Scheduler ordering invariants.
9. Single-block DEFLATE round trip (stored, fixed, dynamic).
10. Multi-member gzip round trip.

### 12.2 Integration Tests

For each fixture:

```bash
dgz compress   fixture     -o fixture.gz
dgz decompress fixture.gz  -o fixture.out
cmp -s fixture fixture.out

# Interop with stock tools.
gunzip -c fixture.gz | cmp -s - fixture
gzip   -c fixture    | dgz decompress --stdin -o fixture.out2
cmp -s fixture fixture.out2
```

Run with:

```text
--threads 1
--threads 2
--threads auto
--level 1
--level 6
--level 9
```

### 12.3 Negative Tests

1. Invalid gzip magic.
2. Unsupported compression method (anything other than 8).
3. Truncated header.
4. Truncated DEFLATE stream.
5. Bad Huffman code-length sequence.
6. Distance pointing before the start of the window.
7. Wrong CRC32 in trailer.
8. Wrong ISIZE in trailer.
9. Output exists without `--force`.
10. Input file does not exist.

### 12.4 Determinism Tests

1. `dgz compress` of the same input with the same settings produces
   byte-identical output across runs.
2. Same output across different `--threads` values is **not** required
   (member boundaries differ), but each member must be byte-identical
   to a single-threaded compression of that chunk.

### 12.5 Safety Checks

CI runs:

```bash
# No @system anywhere in new code.
! grep -RE '\b@system\b' packages/compressor packages/compress-cli

# No @trusted outside the audited shim.
! grep -RE '\b@trusted\b' packages/compressor packages/compress-cli \
  | grep -v 'compressor/unsafe.d'

dub test  :compressor   --config=unittest
dub build :compress-cli --build=release
```

Optionally `dscanner` with attribute analysis once the codebase
stabilizes.

### 12.6 Container Validation

Create `tests/compose.yml` so the new project validates
independently with the same convention used by the existing port:

```bash
podman compose -f tests/compose.yml run --rm test-safe-d
```

Inside the container the entrypoint runs the unit tests, builds the
CLI in release mode, and runs the gzip interop tests against stock
`gzip` / `gunzip`.

---

## 13. Implementation Phases

### Phase 0 - Planning And Baseline

Deliverables:

1. This Markdown plan.
2. Confirm current D baseline builds without modification:
   ```bash
   cd sevenzip-d
   dub test  :core --config=unittest
   dub build :core --config=betterc
   podman compose -f tests/compose.yml run --rm test-d-port
   ```
3. Final package and executable names locked.

Exit criteria:

1. Plan reviewed and accepted.
2. Baseline green and recorded.
3. No implementation has started.

### Phase 1 - Safe Skeleton, gzip Container, `store` Codec

Deliverables:

1. `packages/compressor` and `packages/compress-cli` packages.
2. `unsafe.d` shim with the minimum required wrappers.
3. CRC32 + bit writer + bit reader.
4. gzip header/trailer encode/decode.
5. `store` mode: DEFLATE BTYPE=00 only (no compression), wrapped in gzip.
6. CLI commands: `compress`, `decompress`, `test`, `info`, with atomic
   output, signal handling, and exit codes.

Exit criteria:

1. `store` round trips pass.
2. `dgz compress --store` output is decompressed by stock `gunzip`.
3. CLI handles errors and exit codes.
4. Packages compile with `-preview=dip1000`.
5. CI safety grep passes.
6. No existing repository code is replaced or moved.

### Phase 2 - Safe DEFLATE Encoder And Decoder

Deliverables:

1. Hash-chain match finder.
2. Greedy + lazy matcher.
3. Huffman builder with 15-bit length limit.
4. Block emitter choosing among stored / fixed / dynamic blocks.
5. Full DEFLATE decoder.
6. Replace `store` with real DEFLATE as the default.

Exit criteria:

1. All round-trip tests in §10.4 pass.
2. Interop tests against stock `gzip` / `gunzip` pass.
3. Corruption tests in §12.3 fail cleanly with typed errors.
4. CI safety grep still passes.

### Phase 3 - Multicore (concatenated gzip members)

Deliverables:

1. Bounded worker scheduler over `core.thread`.
2. Per-worker encoder state.
3. Ordered writer on the main thread.
4. `--threads` and `--chunk-size` options.
5. Thread scaling benchmarks.

Exit criteria:

1. `--threads 1`, `--threads 2`, `--threads auto` all round trip.
2. Output is deterministic for fixed settings (§6.4).
3. Multi-member output is decompressed by stock `gunzip`, `zcat`, and
   `pigz`.
4. Peak memory remains bounded per §9.3.
5. Compression speed scales sub-linearly but meaningfully on inputs
   large enough to benefit.

### Phase 4 - Performance Tuning

Deliverables:

1. Final level-to-settings table.
2. Buffer reuse across chunks per worker.
3. Reduced allocations in hot paths (target: zero allocation per block
   after warmup).
4. Benchmark documentation.
5. Optional parallel decompression of concatenated members.

Exit criteria:

1. Release build benchmarks recorded.
2. Memory use documented.
3. No regression in safety checks.

### Phase 5 - Optional LZMA2 Codec

Deliverables:

1. Safe LZMA2 block encoder (or, if accepted, an explicitly-bounded
   `@trusted` shim over `C/Lzma2Enc.c` living entirely in `unsafe.d`).
2. `--codec lzma2` option.
3. `.xz` container writer/reader (per the XZ format spec).
4. Round trips against stock `xz` / `unxz`.

Exit criteria:

1. LZMA2 round trips pass.
2. `.xz` interop with stock tools passes.
3. Safety policy unchanged: no `@trusted` outside `unsafe.d`.

### Phase 6 - Optional Compatibility Extensions

Deliverables:

1. `.7z` archive writer after archive update support exists.
2. ZSTD codec only if a safe encoder becomes available.

Exit criteria:

1. Compatibility format round trips pass against external reference
   tools.
2. The gzip and `.xz` paths remain supported.

---

## 14. Risks And Mitigations

| Risk | Impact | Mitigation |
|---|---:|---|
| Hash-chain match finder is too slow at level 9 | Medium | Cap chain length; document level-9 as "best ratio, not best speed"; add binary-tree finder in Phase 4 only if needed. |
| 100% `@safe` claim conflicts with I/O / threading | High | Bounded `@trusted` shim in `unsafe.d`, enforced by CI grep; everything else `@safe`. |
| New project couples too tightly to existing port | High | Separate top-level directory; additive build/test flow. |
| Independent gzip members reduce ratio slightly | Low | Document tradeoff; default `chunkSize=1 MiB` keeps the cost small; `--threads 1` produces single-member output. |
| Memory grows with thread count | Medium | Bounded in-flight queue; per-worker buffer reuse; documented memory formula. |
| Determinism breaks under concurrency | Medium | Chunking and per-block decisions are pure functions of input; gzip header fields fixed. |
| Custom `Result!T` design churn | Low | Lock the shape in Phase 1 with unit tests; do not refactor it in later phases. |
| LZMA2 (Phase 5) larger than estimated | High | Already deferred behind a stable, shipped DEFLATE pipeline; v1 is shippable without it. |
| `gzip` is "uncool" vs. modern codecs | Low | Universal interop is a feature; LZMA2 / `.xz` is the planned high-ratio answer. |

---

## 15. Acceptance Criteria For First Usable Release

The first usable release is complete when all of these are true:

1. `dgz compress input -o input.gz` creates a gzip-compatible file.
2. `dgz decompress input.gz -o input.out` restores byte-identical data.
3. Empty, small, large, repeated, and random files round trip.
4. `gunzip -c input.gz` produces the original input byte-for-byte.
5. `dgz decompress` correctly handles output produced by stock `gzip`
   and by `pigz` (concatenated members).
6. `--threads 1` and `--threads auto` both work and both produce valid
   gzip output.
7. Output is deterministic for fixed settings (§6.4, §12.4).
8. Corrupt input returns a nonzero exit code and a clear error message.
9. `packages/compressor` and `packages/compress-cli` compile with
   `-preview=dip1000`.
10. CI safety grep passes: no `@system` in new code, and no `@trusted`
    outside `packages/compressor/source/sevenzip/compressor/unsafe.d`.
11. Container validation passes:
    `podman compose -f tests/compose.yml run --rm test-safe-d`.
12. Basic benchmark numbers are documented.
13. Documentation states v1 is DEFLATE-in-gzip; LZMA2 is a planned
    optional codec.
14. The implementation resides in a new directory and does not replace
    existing repository code.

---

## 16. Initial Work Order After This Plan Is Accepted

1. Verify baseline:

   ```bash
   cd sevenzip-d
   dub test  :core --config=unittest
   dub build :core --config=betterc
   podman compose -f tests/compose.yml run --rm test-d-port
   ```

2. Create the root-level workspace `dub.sdl` and package layout.
3. Add `packages/compressor` skeleton with `errors.d`, `settings.d`,
   `checksum.d` (CRC32), `bitwriter.d`, `gzip.d`, and `unsafe.d`.
4. Add `packages/compress-cli` with argument parsing, atomic output,
   and signal handling.
5. Add the `store` mode (BTYPE=00 in gzip) to validate framing, CLI,
   tests, and threading skeleton.
6. Add `tests/compose.yml` and the `test-safe-d` service; add gzip
   interop integration tests.
7. Begin the DEFLATE encoder milestone (Phase 2) only after the safe
   skeleton and `store`-mode interop are green.

---

## 17. Final Recommendation

Start with a safe high-level D **DEFLATE** encoder + decoder, emit
**standard gzip** output, and exploit multicore through **concatenated
gzip members** in `pigz` style. This is the smallest path to a real,
interoperable CLI in this repository while preserving the important
constraints: hot-path `@safe`, DIP1000, high-level D APIs, multicore
performance, and no replacement of existing code.

LZMA2 remains a planned later codec for high-ratio mode. ZSTD and
Brotli stay out of scope; their encoders are larger than LZMA2's and
offer no advantage for this project's first release.
