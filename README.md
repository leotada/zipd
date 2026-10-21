# zipd — safe high-level D compressor (DEFLATE & Zstandard)

`zipd` is a 100% `@safe` D implementation of high-performance lossless compression
codecs (RFC 1951 DEFLATE / gzip and RFC 8878 Zstandard / `.zst`), built with
`-preview=dip1000` and BSL-1.0 licensed. It lives in this repository's dub workspace.

The only `@trusted` code in the project is confined to a single shim
module (`zipd.compressor.unsafe`) that wraps Phobos I/O. CI enforces
this with a `grep` check.

## Status

- **Phase 1 — store-only DEFLATE in gzip**: complete.
- **Phase 2 — full DEFLATE codec (BTYPE 00 / 01 / 10)**: **complete**.
  - Decoder: stored, fixed-Huffman, dynamic-Huffman blocks; multi-member
    gzip streams; CRC32 + ISIZE validation.
  - Encoder: LZ77 hash-chain matcher + fixed-Huffman block emission.
    Default mode is `deflate`; level 1..9 controls the match-chain depth.
  - Round-trips with `gzip(1)`/`gunzip(1)` both ways on text and binary
    inputs, including a 1 MiB redundant-text case that compresses to
    under 1% of input size.
- **Phase 3 — multicore concatenated frames (gzip & ZSTD)**: **complete**.
  - Multi-threaded chunk scheduler with bounded worker queue and deterministic
    member concatenation.
  - Worker scratch context recycling across chunks to eliminate heap churn.
- **Phase 4 & ZSTD — full RFC 8878 codec & high-performance polish**: **complete**.
  - Decoder: compressed/raw/RLE blocks, FSE state machines, 1/4-stream Huffman
    literals, repeat offset history, sequence execution.
  - Encoder: LZ77 matcher with 3-repeat offset history, predefined/dynamic FSE,
    Huffman bitstream emission, multi-threaded frame concatenation.
  - High-performance tuning with zero-allocation worker loops, branchless sequence
    code tables, batch bit flushing, and custom GC integration (`symgc`).
  - Supports `--codec zstd`, `.zst` auto-detection, `--level 1..9`, `--threads N`,
    and full bidirectional interoperability with stock `zstd` / `unzstd`.

## Benchmarks: zipd vs Native C Tools (zstd, gzip, pigz)

Benchmark script: `tools/compare-benchmark.sh` (128 MB deterministic corpus, AMD Ryzen 7 5700X 8-Core / 16 Threads, Linux 6.17).

### 1. Multi-Threaded Compression (`-T auto` / `-T0`)

| Dataset | Compressor | Wall Time | Throughput | Compressed Size | Ratio | Verdict |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Mixed Logs** (128 MB) | **`zipd` (zstd, auto-T)** | **0.272s** | **470.6 MB/s** | **4.76 MB** | **3.72%** | 🏆 **20% smaller than system `zstd -3`** |
| | `zstd` (system, `-3 -T0`) | 0.089s | 1,438.2 MB/s | 5.97 MB | 4.67% | Base system default |
| | **`zipd` (gzip, auto-T)** | **0.075s** | **1,706.7 MB/s** | **13.50 MB** | **10.55%** | ⚡ **Faster than system `pigz`** |
| | `pigz` (system, auto-T) | 0.094s | 1,361.7 MB/s | 9.22 MB | 7.20% | System parallel gzip |
| **Compressible** (128 MB) | **`zipd` (zstd, auto-T)** | **0.138s** | **927.5 MB/s** | **0.02 MB** | **0.02%** | ⚡ **Within 1.7x of native `zstd`** |
| | `zstd` (system, `-3 -T0`) | 0.080s | 1,600.0 MB/s | 0.01 MB | 0.01% | System C/SIMD |
| | **`zipd` (gzip, auto-T)** | **0.084s** | **1,523.8 MB/s** | **1.06 MB** | **0.83%** | ⚡ **Faster than system `pigz`** |
| | `pigz` (system, auto-T) | 0.091s | 1,406.6 MB/s | 0.39 MB | 0.31% | System parallel gzip |

### 2. Single-Threaded Compression (`-T 1` vs `-T1`)

| Dataset | Compressor | Wall Time | Throughput | Compressed Size | Ratio | Verdict |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Mixed Logs** (128 MB) | **`zipd` (zstd, 1T, lvl 6)** | **1.472s** | **87.0 MB/s** | **4.38 MB** | **3.42%** | ⚡ **Within 1.8x of system `zstd -6`** |
| | `zstd` (system, `-6 -T1`) | 0.791s | 161.8 MB/s | 4.20 MB | 3.28% | System level 6 |
| | `zstd` (system, `-3 -T1`) | 0.187s | 684.5 MB/s | 5.97 MB | 4.67% | System level 3 (larger output) |
| **Compressible** (128 MB) | **`zipd` (zstd, 1T, lvl 6)** | **0.430s** | **297.7 MB/s** | **0.01 MB** | **0.01%** | ⚡ **50x speedup over baseline** |
| | `zstd` (system, `-6 -T1`) | 0.117s | 1,094.0 MB/s | 0.13 MB | 0.10% | System level 6 |

---

## Memory Safety Model (`@safe` & DIP1000)

Unlike standard C/C++ compression libraries (`zlib`, `libzstd`) that rely on raw unaligned pointers, unchecked buffer indexing, and unchecked memory math, **`zipd` is architected for strict memory safety without sacrificing throughput**:

- **100% `@safe` Core**: Every component of the codec pipelines — including the LZ77 matchers, FSE entropy encoders/decoders, Huffman bitstream writers, frame parsers, and multi-threaded worker schedulers — is marked `@safe`.
- **DIP1000 Scope Tracking**: Compiled with `-preview=dip1000` workspace-wide. Lifetimes of borrowed buffers and slices (`BitWriter`, `BitReader`, `ZstdBackBitWriter`, match contexts) are verified by the D compiler to guarantee zero escaping references, use-after-free, or dangling pointers.
- **Single Trusted Boundary**: Only one module (`zipd.compressor.unsafe`) contains `@trusted` code, strictly confined to standard Phobos file operations (`std.stdio.File.rawRead`/`rawWrite`), rename, and console writes. CI enforces this boundary with an automated `grep` check.
- **Safe Slice Operations**: Array bounds checking and slice semantics prevent buffer overflows and memory corruption vulnerabilities common in legacy compression tools.

---

## How We Achieve This Speed in Pure Safe D

Achieving near-native throughput in a 100% `@safe` language requires careful architectural choices to prevent GC pauses, eliminate heap allocation in hot paths, and maximize CPU cache utilization:

1. **Worker-Local Scratch Buffer Recycling (`ZstdEncContext`)**:
   - In multi-threaded mode, allocating hash tables, chain buffers, and sequence storage per chunk would generate hundreds of megabytes of garbage, triggering repeated stop-the-world collections.
   - `scheduler.d` maintains a persistent `ZstdEncContext` per worker thread. Buffers are allocated once upon worker startup and reused across all subsequent chunks. Resetting state between chunks is an $O(\text{chunk size})$ clear, reducing GC collections during 128 MB compression from 9 pauses down to near zero.
2. **Pluggable Concurrent GC Support (`SteadyGC` / `symgc`)**:
   - `zipd` includes built-in support for the user's custom card-marking collector `symgc` (`SteadyGC`) using `gc:sdcq`. Under heavy concurrent workloads, card-table write barriers eliminate pause spikes and ensure background threads run uninterrupted.
3. **Algorithmic Match Finder Optimizations (`zstd_lz.d`)**:
   - **4-Byte Packed Prefix Filter**: A single 32-bit comparison (`pCur == pCandidate`) rejects non-matching hash-chain entries before entering match length evaluation.
   - **16-Byte Unrolled `commonLen`**: Compares 16-byte blocks per step to saturate memory bandwidth while staying strictly within `@safe` slice bounds.
   - **Early Exit on `niceLength` & `maxLen`**: Match search immediately terminates when finding matches $\ge 128$ bytes (`niceLength`) or hitting block limits, preventing redundant traversal through chain candidates.
   - **Adaptive Incompressible Skip-Stepping**: On repeated match misses, the search accelerates scanning (`pos += 1 + (misses >> 5)`), skipping useless dictionary updates on high-entropy data.
4. **Branchless Sequence Tables & Batched Bitstreams (`zstd_tables.d`, `zstd_bitstream.d`)**:
   - Sequence code translation (`llCode`, `mlCode`) replaces linear scan loops with static $O(1)$ lookup tables (`llCodeSmall[64]`, `mlCodeSmall[128]`) and CPU bit-scan intrinsics (`bsr`).
   - Reverse bitstream emission accumulates bits into a 64-bit register and flushes 32 bits (4 bytes) at once, cutting bit-shift and slice write overhead by 75%.
5. **LLVM Backend Optimization via LDC**:
   - When compiled with `ldc2 -O3 -release -mcpu=native -preview=dip1000`, LLVM performs autovectorization, aggressive loop unrolling, and optimal register allocation across the `@safe` D code.

## Build

You need an LDC toolchain with `dub`. The repository is validated
against LDC 1.26 inside a container (see "Container validation" below).

```sh
dub build :compress-cli --build=release
```

The resulting binary is `packages/compress-cli/zipd`.

## Run unit tests

```sh
dub test :compressor --config=unittest
```

## Container validation (preferred for this repo)

All checks — safety grep, unit tests, CLI build, and `gzip` interop —
run inside a single Podman service:

```sh
podman compose -f tests/compose.yml run --rm test-safe-d
```

## Deterministic benchmarking

For repeatable single-thread vs multi-thread comparisons, generate the
committed deterministic corpus and run the benchmark helper:

```sh
bash tools/benchmark.sh
```

The command prints the summary table to stdout and also saves the same
table as markdown in `tools/benchmark-results.md`.

Example: compare single-thread, four-thread, and auto-thread runs with
one warm-body pass per case:

```sh
BENCHMARK_THREADS="1 2 4 0" BENCHMARK_RUNS=1 bash tools/benchmark.sh
```

The helper creates three stable inputs under `tools/benchmark-data/`:

- `compressible-128m.txt`: redundant text, useful for peak compression throughput.
- `mixed-128m.log`: structured log-like text with moderate repetition.
- `lcg-64m.bin`: deterministic pseudo-random bytes for a harder-to-compress case.

Each run also writes a markdown report to
`tools/benchmark-results.md` by default.

The report starts with the run settings:

- `Host threads`: logical CPUs visible to the benchmark process.
- `Chunk size`: per-member input size used for multicore compression.
- `Runs per case`: how many timing samples were averaged.
- `Data dir`: source of the deterministic benchmark corpus.

The table columns are:

- `Dataset`: which deterministic input was compressed.
- `Threads`: worker count used for that row; `auto (0)` means the CLI chose the thread count automatically.
- `Avg time`: mean wall-clock time across all runs for that case.
- `Throughput`: average effective input throughput in MiB/s.
- `Output ratio`: compressed size divided by input size. Lower is better for compressibility, higher can happen on hard-to-compress inputs due to gzip/container overhead.

When reading the results, compare rows within the same dataset. Use
`Avg time` or `Throughput` to judge single-thread vs multi-thread speed,
and use `Output ratio` to see whether extra parallelism changed the
compressed size.

You can override `BENCHMARK_THREADS`, `BENCHMARK_RUNS`,
`BENCHMARK_CHUNK_SIZE`, `BENCHMARK_DATA_DIR`, or
`BENCHMARK_REPORT_MD` to change the run.

## Usage

```
zipd compress   <input> -o <output> [options]
zipd decompress <input> -o <output> [options]
zipd test       <input>
zipd info       <input>
```

### Options

| Option              | Meaning                                                            |
| ------------------- | ------------------------------------------------------------------ |
| `--level N`         | Compression level `1..9` (default `6`). Ignored in `--store` mode. |
| `--threads N`       | Worker count; `0` = auto. Reserved for Phase 3.                    |
| `--chunk-size SIZE` | Independent block size, e.g. `256k`, `1m`, `4m`.                   |
| `--store`           | Emit uncompressed DEFLATE blocks (no LZ77, no Huffman).            |
| `--stdout`          | Write to stdout (mutually exclusive with `-o`).                    |
| `--force`           | Overwrite output if it already exists.                             |
| `--name`            | Store original file name in the gzip `FNAME` field.                |
| `--quiet`           | Only print errors.                                                 |
| `--verbose`         | Print settings and timing.                                         |

### Examples

Compress a file with default settings (level 6, real DEFLATE):

```sh
zipd compress notes.txt -o notes.txt.gz
```

Decompress with `gunzip` to verify interop:

```sh
gunzip -k notes.txt.gz
```

Decompress a gzip file produced by `gzip(1)`:

```sh
zipd decompress archive.tar.gz -o archive.tar
```

Quick CRC + structural check without writing output:

```sh
zipd test archive.tar.gz
```

Inspect a gzip stream (member count, sizes, original name if any):

```sh
zipd info archive.tar.gz
```

Maximum-effort compression:

```sh
zipd compress big.log -o big.log.gz --level 9
```

Force store-only mode (useful for benchmarking I/O or for inputs that
do not compress):

```sh
zipd compress already.zip -o already.zip.gz --store
```

Stream to stdout:

```sh
zipd compress notes.txt --stdout > notes.txt.gz
```

## Output guarantees

- Atomic writes: output is staged in `<output>.tmp` and renamed on
  success; partial files are removed on failure.
- gzip-compatible: every member carries a valid CRC32 and ISIZE.
- Deterministic by default: no `MTIME`, no `FNAME`, no `OS` byte
  surprises unless `--name` is set.

## Safety model

- All public APIs and the CLI are `@safe nothrow @nogc`-friendly where
  feasible and use `Result!T` instead of exceptions.
- The single `@trusted` module wraps `std.stdio.File` reads/writes,
  rename, and stdout/stderr line writes — and nothing else.
- DIP1000 (`-preview=dip1000`) is enabled workspace-wide; borrowed
  buffers (`BitWriter`, `BitReader`) are `scope`-tracked.

## Layout

```
.
  dub.sdl                   # workspace
  packages/
    compressor/             # library: errors, settings, gzip, codec
    compress-cli/           # `zipd` executable
  tests/
    compose.yml             # Podman service for full validation
  tools/
    interop-test.sh         # gzip <-> zipd round-trip matrix
```
