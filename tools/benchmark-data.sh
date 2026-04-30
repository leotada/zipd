#!/usr/bin/env bash
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT_DIR="${1:-$ROOT_DIR/tools/benchmark-data}"
GEN_SRC="$ROOT_DIR/tools/benchmark_data.d"
GEN_BIN="$ROOT_DIR/tools/.benchmark-data-gen"
GEN_RUNNER="$GEN_BIN"

compiler="${DC:-}"
if [[ -z "$compiler" ]]; then
    if command -v ldc2 >/dev/null 2>&1; then
        compiler=ldc2
    elif command -v dmd >/dev/null 2>&1; then
        compiler=dmd
    else
        echo "benchmark-data: need ldc2 or dmd in PATH" >&2
        exit 1
    fi
fi

if [[ ! -x "$GEN_BIN" || "$GEN_SRC" -nt "$GEN_BIN" ]]; then
    "$compiler" -O -release -of="$GEN_BIN" "$GEN_SRC"
fi

case "$compiler" in
    *ldc2*)
        compiler_path=$(command -v "$compiler")
        compiler_root=$(CDPATH= cd -- "$(dirname -- "$compiler_path")/.." && pwd)
        ldc_lib_dir="$compiler_root/lib"
        if [[ -d "$ldc_lib_dir" ]]; then
            GEN_RUNNER="env LD_LIBRARY_PATH=$ldc_lib_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH} $GEN_BIN"
        fi
        ;;
esac

if [[ "$GEN_RUNNER" == "$GEN_BIN" ]]; then
    RUN_CMD=("$GEN_BIN" "$OUT_DIR")
else
    RUN_CMD=(env "LD_LIBRARY_PATH=$ldc_lib_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$GEN_BIN" "$OUT_DIR")
fi

mkdir -p "$OUT_DIR"
"${RUN_CMD[@]}"