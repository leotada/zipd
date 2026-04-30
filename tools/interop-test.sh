#!/usr/bin/env bash
# Interop tests: dgz <-> stock gzip/gunzip.
# Note: pipefail is intentionally NOT set, since several inputs are
# generated via `yes ... | head -c N` which causes a SIGPIPE (141) on
# the `yes` side once head closes the pipe.
set -eu

DGZ="${DGZ:-./packages/compress-cli/dgz}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$DGZ" ]]; then
    echo "interop-test: $DGZ not found or not executable" >&2
    exit 1
fi

run_case () {
    local name="$1" gen="$2"
    local in="$TMP/$name.in" gz="$TMP/$name.gz" out="$TMP/$name.out"
    eval "$gen" > "$in"

    # dgz -> gunzip round trip.
    "$DGZ" compress "$in" -o "$gz" --quiet
    gunzip -c "$gz" > "$out"
    cmp -s "$in" "$out" || { echo "FAIL ($name): dgz->gunzip mismatch" >&2; exit 1; }

    # dgz self round trip.
    rm -f "$gz" "$out"
    "$DGZ" compress   "$in" -o "$gz"  --quiet
    "$DGZ" decompress "$gz" -o "$out" --quiet
    cmp -s "$in" "$out" || { echo "FAIL ($name): dgz->dgz mismatch" >&2; exit 1; }

    # gzip -> dgz round trip (Phase 2: full Huffman decoder).
    rm -f "$gz" "$out"
    gzip -c "$in" > "$gz"
    "$DGZ" decompress "$gz" -o "$out" --quiet
    cmp -s "$in" "$out" || { echo "FAIL ($name): gzip->dgz mismatch" >&2; exit 1; }

    echo "ok: $name"
}

# Phase 1: dgz emits stored (BTYPE=00) blocks; gunzip handles them.
run_case empty   ': '
run_case small   'echo -n hello'
run_case repeat  'yes a | head -c 100000'
run_case binary  'head -c 200000 /dev/urandom'
run_case bigtext 'yes "the quick brown fox jumps over the lazy dog" | head -c 1500000'

# Stress: a multi-member gzip stream produced by concatenating two
# stock gzip outputs. Our decoder must consume both members.
echo "checking multi-member gzip..."
echo aaa > "$TMP/m1"
echo bbb > "$TMP/m2"
gzip -c "$TMP/m1" >  "$TMP/multi.gz"
gzip -c "$TMP/m2" >> "$TMP/multi.gz"
"$DGZ" decompress "$TMP/multi.gz" -o "$TMP/multi.out" --quiet
cat "$TMP/m1" "$TMP/m2" > "$TMP/multi.want"
cmp -s "$TMP/multi.want" "$TMP/multi.out" \
    || { echo "FAIL: multi-member mismatch" >&2; exit 1; }
echo "ok: multi-member"

# Compression-ratio sanity check: a 1 MiB highly-redundant payload
# must compress to under 10% of its original size with the Huffman
# encoder. (Pure store mode would emit ~100%, so this catches a
# silent regression to BTYPE=00.)
echo "checking compression ratio on redundant input..."
yes "the quick brown fox" | head -c 1048576 > "$TMP/r.in"
"$DGZ" compress "$TMP/r.in" -o "$TMP/r.gz" --quiet
in_sz=$(wc -c < "$TMP/r.in")
out_sz=$(wc -c < "$TMP/r.gz")
echo "  input=$in_sz bytes, gzip=$out_sz bytes"
if (( out_sz * 10 > in_sz )); then
    echo "FAIL: compression ratio worse than 10:1 ($out_sz vs $in_sz)" >&2
    exit 1
fi
echo "ok: ratio"

# Phase 3: multi-threaded compression. Output is concatenated gzip
# members; stock gunzip must round-trip and dgz must too.
echo "checking multi-threaded compression..."
head -c 4194304 /dev/urandom > "$TMP/mt.in"

for THREADS in 1 2 4; do
    rm -f "$TMP/mt.gz" "$TMP/mt.out"
    "$DGZ" compress   "$TMP/mt.in" -o "$TMP/mt.gz" \
        --threads "$THREADS" --chunk-size 256k --quiet
    gunzip -c "$TMP/mt.gz" > "$TMP/mt.out"
    cmp -s "$TMP/mt.in" "$TMP/mt.out" \
        || { echo "FAIL: --threads=$THREADS dgz->gunzip mismatch" >&2; exit 1; }
    rm -f "$TMP/mt.out"
    "$DGZ" decompress "$TMP/mt.gz" -o "$TMP/mt.out" --quiet
    cmp -s "$TMP/mt.in" "$TMP/mt.out" \
        || { echo "FAIL: --threads=$THREADS dgz->dgz mismatch" >&2; exit 1; }
    echo "ok: --threads=$THREADS"
done

# Determinism: same input + settings must produce byte-identical output.
echo "checking multi-threaded determinism..."
"$DGZ" compress "$TMP/mt.in" -o "$TMP/mt.a.gz" \
    --threads 4 --chunk-size 256k --quiet
"$DGZ" compress "$TMP/mt.in" -o "$TMP/mt.b.gz" \
    --threads 4 --chunk-size 256k --quiet
cmp -s "$TMP/mt.a.gz" "$TMP/mt.b.gz" \
    || { echo "FAIL: multi-threaded output is not deterministic" >&2; exit 1; }
echo "ok: determinism"

# Auto threads (--threads 0 default) must also produce a valid gzip.
"$DGZ" compress "$TMP/mt.in" -o "$TMP/mt.auto.gz" --quiet
gunzip -c "$TMP/mt.auto.gz" > "$TMP/mt.auto.out"
cmp -s "$TMP/mt.in" "$TMP/mt.auto.out" \
    || { echo "FAIL: --threads=auto mismatch" >&2; exit 1; }
echo "ok: --threads=auto"

echo "all interop tests passed"
