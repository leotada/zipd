#!/usr/bin/env bash
# Fast comparative benchmark: zipd vs system tools (zstd, gzip, pigz)
# Finishes in ~30-45 seconds.
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ZIPD="${ZIPD:-$ROOT_DIR/packages/compress-cli/zipd}"
DATA_DIR="${BENCHMARK_DATA_DIR:-$ROOT_DIR/tools/benchmark-data}"

bash "$ROOT_DIR/tools/benchmark-data.sh" "$DATA_DIR" >/dev/null

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=== System Compression Benchmark (zipd vs zstd / pigz / gzip) ==="
echo "Host CPUs: $(nproc)"
echo

printf "%-28s %-20s %10s %10s %12s %10s
"   "Tool & Config" "Dataset" "Time (s)" "Speed(MB/s)" "Comp Size" "Ratio"
printf "%s
" "--------------------------------------------------------------------------------------------------"

bench_one() {
    local label="$1"
    local cmd="$2"
    local input="$3"
    local dataset="$4"
    local out="$TMP_DIR/out.bin"
    rm -f "$out"

    local in_bytes
    in_bytes=$(wc -c < "$input")

    local start_ns end_ns elapsed_s
    start_ns=$(date +%s%N)
    eval "$cmd" >/dev/null
    end_ns=$(date +%s%N)

    elapsed_s=$(awk -v s="$start_ns" -v e="$end_ns" 'BEGIN {printf "%.3f", (e - s)/1000000000}')
    local out_bytes
    out_bytes=$(wc -c < "$out")

    local speed_mibs ratio_pct
    speed_mibs=$(awk -v b="$in_bytes" -v s="$elapsed_s" 'BEGIN {if (s>0) printf "%.1f", (b/1048576)/s; else printf "inf"}')
    ratio_pct=$(awk -v i="$in_bytes" -v o="$out_bytes" 'BEGIN {printf "%.2f%%", (o/i)*100}')
    local out_human
    out_human=$(awk -v o="$out_bytes" 'BEGIN {printf "%.2f MB", o/1048576}')

    printf "%-28s %-20s %10s %10s %12s %10s
"       "$label" "$dataset" "${elapsed_s}s" "$speed_mibs" "$out_human" "$ratio_pct"
}

# Datasets:
# 1. Text / Log: mixed-128m.log (128 MB)
# 2. Redundant text: compressible-128m.txt (128 MB)

for ds in "compressible-128m.txt:Compressible" "mixed-128m.log:Mixed-Log"; do
    file="$DATA_DIR/${ds%%:*}"
    name="${ds##*:}"

    echo "--- Dataset: $name (128 MB) ---"

    # Single-thread ZSTD comparison
    bench_one "zipd (zstd, 1T, lvl 6)"               ""$ZIPD" compress "$file" -o "$TMP_DIR/out.bin" --codec zstd --threads 1 --quiet"               "$file" "$name"

    bench_one "zstd (system, 1T, -6)"               "zstd -6 -T1 -c "$file" > "$TMP_DIR/out.bin""               "$file" "$name"

    bench_one "zstd (system, 1T, -3 default)"               "zstd -3 -T1 -c "$file" > "$TMP_DIR/out.bin""               "$file" "$name"

    # Multi-thread ZSTD comparison
    bench_one "zipd (zstd, multi-T auto)"               ""$ZIPD" compress "$file" -o "$TMP_DIR/out.bin" --codec zstd --threads 0 --quiet"               "$file" "$name"

    bench_one "zstd (system, multi-T auto)"               "zstd -T0 -c "$file" > "$TMP_DIR/out.bin""               "$file" "$name"

    # Single-thread DEFLATE / GZIP comparison
    bench_one "zipd (gzip, 1T, lvl 6)"               ""$ZIPD" compress "$file" -o "$TMP_DIR/out.bin" --codec deflate --threads 1 --quiet"               "$file" "$name"

    bench_one "gzip (system, -6 default)"               "gzip -c "$file" > "$TMP_DIR/out.bin""               "$file" "$name"

    # Multi-thread DEFLATE comparison
    if command -v pigz >/dev/null 2>&1; then
        bench_one "zipd (gzip, multi-T auto)"                   ""$ZIPD" compress "$file" -o "$TMP_DIR/out.bin" --codec deflate --threads 0 --quiet"                   "$file" "$name"

        bench_one "pigz (system, multi-T auto)"                   "pigz -c "$file" > "$TMP_DIR/out.bin""                   "$file" "$name"
    fi

    echo
done
