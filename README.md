# dgz — safe high-level D gzip-compatible compressor

`dgz` is a 100% `@safe` D implementation of a gzip-compatible lossless
compressor, built with `-preview=dip1000` and BSL-1.0 licensed. It lives
in this repository's dub workspace.

The only `@trusted` code in the project is confined to a single shim
module (`sevenzip.compressor.unsafe`) that wraps Phobos I/O. CI enforces
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
- **Phase 3 — multicore concatenated gzip members**: not started.
- **Phase 4 — performance polish**: not started.

## Build

You need an LDC toolchain with `dub`. The repository is validated
against LDC 1.26 inside a container (see "Container validation" below).

```sh
dub build :compress-cli --build=release
```

The resulting binary is `packages/compress-cli/dgz`.

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
dgz compress   <input> -o <output> [options]
dgz decompress <input> -o <output> [options]
dgz test       <input>
dgz info       <input>
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
dgz compress notes.txt -o notes.txt.gz
```

Decompress with `gunzip` to verify interop:

```sh
gunzip -k notes.txt.gz
```

Decompress a gzip file produced by `gzip(1)`:

```sh
dgz decompress archive.tar.gz -o archive.tar
```

Quick CRC + structural check without writing output:

```sh
dgz test archive.tar.gz
```

Inspect a gzip stream (member count, sizes, original name if any):

```sh
dgz info archive.tar.gz
```

Maximum-effort compression:

```sh
dgz compress big.log -o big.log.gz --level 9
```

Force store-only mode (useful for benchmarking I/O or for inputs that
do not compress):

```sh
dgz compress already.zip -o already.zip.gz --store
```

Stream to stdout:

```sh
dgz compress notes.txt --stdout > notes.txt.gz
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
    compress-cli/           # `dgz` executable
  tests/
    compose.yml             # Podman service for full validation
  tools/
    interop-test.sh         # gzip <-> dgz round-trip matrix
```
