#!/usr/bin/env bash
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ZIPD="${ZIPD:-$ROOT_DIR/packages/compress-cli/zipd}"
DATA_DIR="${BENCHMARK_DATA_DIR:-$ROOT_DIR/tools/benchmark-data}"
REPORT_MD="${BENCHMARK_REPORT_MD:-$ROOT_DIR/tools/benchmark-results.md}"
THREADS="${BENCHMARK_THREADS:-1 2 4 0}"
RUNS="${BENCHMARK_RUNS:-3}"
CHUNK_SIZE="${BENCHMARK_CHUNK_SIZE:-1m}"
HOST_THREADS=$(nproc)

cd "$ROOT_DIR"

if [[ ! -x "$ZIPD" ]]; then
    dub build :compress-cli --build=release >/dev/null
fi

bash "$ROOT_DIR/tools/benchmark-data.sh" "$DATA_DIR" >/dev/null

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
RESULTS_FILE="$TMP_DIR/results.tsv"

: > "$RESULTS_FILE"
GC_STATS_FILE="$TMP_DIR/gc_stats.tsv"
: > "$GC_STATS_FILE"
mkdir -p "$(dirname "$REPORT_MD")"

echo "benchmark_host_threads=$HOST_THREADS"
echo "chunk_size=$CHUNK_SIZE"
echo "runs_per_case=$RUNS"
echo "data_dir=$DATA_DIR"
echo "markdown_report=$REPORT_MD"

bench_case() {
    local dataset="$1"
    local input="$2"
    local threads="$3"
    local output="$TMP_DIR/${dataset}.${threads}.gz"
    local times="$TMP_DIR/${dataset}.${threads}.times"

    : > "$times"
    for _ in $(seq 1 "$RUNS"); do
        rm -f "$output"
        local start_ns end_ns
        start_ns=$(date +%s%N)
        "$ZIPD" compress "$input" -o "$output" \
            --threads "$threads" --chunk-size "$CHUNK_SIZE" --quiet >/dev/null
        end_ns=$(date +%s%N)
        awk -v start="$start_ns" -v end="$end_ns" \
            'BEGIN {printf "%.6f\n", (end - start) / 1000000000}' >> "$times"
    done
    
    # Run once to collect GC stats (not timed)
    "$ZIPD" compress "$input" -o "$output" --threads "$threads" --chunk-size "$CHUNK_SIZE" --quiet --debug 2>> "$GC_STATS_FILE" >/dev/null

    local input_bytes output_bytes avg best ratio avg_mibs
    input_bytes=$(wc -c < "$input")
    output_bytes=$(wc -c < "$output")
    avg=$(awk '{s += $1} END {printf "%.4f", s / NR}' "$times")
    best=$(awk 'NR == 1 || $1 < m {m = $1} END {printf "%.4f", m}' "$times")
    ratio=$(awk -v inb="$input_bytes" -v outb="$output_bytes" \
        'BEGIN {printf "%.4f", outb / inb}')
    avg_mibs=$(awk -v inb="$input_bytes" -v sec="$avg" \
        'BEGIN {printf "%.2f", (inb / 1048576) / sec}')

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$dataset" "$threads" "$input_bytes" "$output_bytes" \
        "$ratio" "$avg" "$best" "$avg_mibs" >> "$RESULTS_FILE"
}

dataset_label() {
    case "$1" in
        compressible) printf '%s' 'Compressible, 128 MiB' ;;
        mixed)        printf '%s' 'Mixed, 128 MiB' ;;
        lcg)          printf '%s' 'LCG binary, 64 MiB' ;;
        *)            printf '%s' "$1" ;;
    esac
}

thread_label() {
    case "$1" in
        0) printf '%s' 'auto (0)' ;;
        *) printf '%s' "$1" ;;
    esac
}

print_table() {
    echo '| Dataset | Threads | Avg time | Throughput | Output ratio |'
    echo '| --- | ---: | ---: | ---: | ---: |'

    while IFS=$'\t' read -r dataset threads _ _ ratio avg _ avg_mibs; do
        printf '| %s | %s | %s s | %s MiB/s | %s%% |\n' \
            "$(dataset_label "$dataset")" \
            "$(thread_label "$threads")" \
            "$avg" \
            "$avg_mibs" \
            "$(awk -v ratio="$ratio" 'BEGIN {printf "%.2f", ratio * 100}')"
    done < "$RESULTS_FILE"
}

write_report() {
    {
        echo '# Benchmark Results'
        echo
        echo "- Host threads: $HOST_THREADS"
        echo "- Chunk size: $CHUNK_SIZE"
        echo "- Runs per case: $RUNS"
        echo "- Data dir: $DATA_DIR"
        echo
        print_table

        echo
        echo "### Accumulated GC Profile"
        echo
        awk '/\[DEBUG\] GC profile:/ {
            cols += $4
            sub(/hnsecs,/, "", $8)
            if ($8 > maxp) maxp = $8
            sub(/hnsecs/, "", $11)
            totp += $11
        }
        END {
            printf "- **Collections (runs):** %d\n", cols
            printf "- **Max Pause:** %d hnsecs\n", maxp
            printf "- **Total Pause:** %d hnsecs\n", totp
        }' "$GC_STATS_FILE"
    } > "$REPORT_MD"
    
    cat "$REPORT_MD"
}

for thread_count in $THREADS; do
    bench_case compressible "$DATA_DIR/compressible-128m.txt" "$thread_count"
done

for thread_count in $THREADS; do
    bench_case mixed "$DATA_DIR/mixed-128m.log" "$thread_count"
done

for thread_count in $THREADS; do
    bench_case lcg "$DATA_DIR/lcg-64m.bin" "$thread_count"
done

write_report

print_table