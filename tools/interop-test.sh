#!/usr/bin/env bash
# Interop tests: zipd <-> stock gzip/gunzip.
# Note: pipefail is intentionally NOT set, since several inputs are
# generated via `yes ... | head -c N` which causes a SIGPIPE (141) on
# the `yes` side once head closes the pipe.
set -eu

ZIPD="${ZIPD:-./packages/compress-cli/zipd}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$ZIPD" ]]; then
    echo "interop-test: $ZIPD not found or not executable" >&2
    exit 1
fi

run_case () {
    local name="$1" gen="$2"
    local in="$TMP/$name.in" gz="$TMP/$name.gz" out="$TMP/$name.out"
    eval "$gen" > "$in"

    # zipd -> gunzip round trip.
    "$ZIPD" compress "$in" -o "$gz" --quiet
    gunzip -c "$gz" > "$out"
    cmp -s "$in" "$out" || { echo "FAIL ($name): zipd->gunzip mismatch" >&2; exit 1; }

    # zipd self round trip.
    rm -f "$gz" "$out"
    "$ZIPD" compress   "$in" -o "$gz"  --quiet
    "$ZIPD" decompress "$gz" -o "$out" --quiet
    cmp -s "$in" "$out" || { echo "FAIL ($name): zipd->zipd mismatch" >&2; exit 1; }

    # gzip -> zipd round trip (Phase 2: full Huffman decoder).
    rm -f "$gz" "$out"
    gzip -c "$in" > "$gz"
    "$ZIPD" decompress "$gz" -o "$out" --quiet
    cmp -s "$in" "$out" || { echo "FAIL ($name): gzip->zipd mismatch" >&2; exit 1; }

    echo "ok: $name"
}

# Phase 1: zipd emits stored (BTYPE=00) blocks; gunzip handles them.
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
"$ZIPD" decompress "$TMP/multi.gz" -o "$TMP/multi.out" --quiet
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
"$ZIPD" compress "$TMP/r.in" -o "$TMP/r.gz" --quiet
in_sz=$(wc -c < "$TMP/r.in")
out_sz=$(wc -c < "$TMP/r.gz")
echo "  input=$in_sz bytes, gzip=$out_sz bytes"
if (( out_sz * 10 > in_sz )); then
    echo "FAIL: compression ratio worse than 10:1 ($out_sz vs $in_sz)" >&2
    exit 1
fi
echo "ok: ratio"

# Phase 3: multi-threaded compression. Output is concatenated gzip
# members; stock gunzip must round-trip and zipd must too.
echo "checking multi-threaded compression..."
head -c 4194304 /dev/urandom > "$TMP/mt.in"

for THREADS in 1 2 4; do
    rm -f "$TMP/mt.gz" "$TMP/mt.out"
    "$ZIPD" compress   "$TMP/mt.in" -o "$TMP/mt.gz" \
        --threads "$THREADS" --chunk-size 256k --quiet
    gunzip -c "$TMP/mt.gz" > "$TMP/mt.out"
    cmp -s "$TMP/mt.in" "$TMP/mt.out" \
        || { echo "FAIL: --threads=$THREADS zipd->gunzip mismatch" >&2; exit 1; }
    rm -f "$TMP/mt.out"
    "$ZIPD" decompress "$TMP/mt.gz" -o "$TMP/mt.out" --quiet
    cmp -s "$TMP/mt.in" "$TMP/mt.out" \
        || { echo "FAIL: --threads=$THREADS zipd->zipd mismatch" >&2; exit 1; }
    echo "ok: --threads=$THREADS"
done

# Determinism: same input + settings must produce byte-identical output.
echo "checking multi-threaded determinism..."
"$ZIPD" compress "$TMP/mt.in" -o "$TMP/mt.a.gz" \
    --threads 4 --chunk-size 256k --quiet
"$ZIPD" compress "$TMP/mt.in" -o "$TMP/mt.b.gz" \
    --threads 4 --chunk-size 256k --quiet
cmp -s "$TMP/mt.a.gz" "$TMP/mt.b.gz" \
    || { echo "FAIL: multi-threaded output is not deterministic" >&2; exit 1; }
echo "ok: determinism"

# Auto threads (--threads 0 default) must also produce a valid gzip.
"$ZIPD" compress "$TMP/mt.in" -o "$TMP/mt.auto.gz" --quiet
gunzip -c "$TMP/mt.auto.gz" > "$TMP/mt.auto.out"
cmp -s "$TMP/mt.in" "$TMP/mt.auto.out" \
    || { echo "FAIL: --threads=auto mismatch" >&2; exit 1; }
echo "ok: --threads=auto"

# Phase 2: ZSTD interop (skipped when stock zstd is not installed).
if command -v zstd >/dev/null 2>&1; then
    echo "checking zstd interop..."
    zstd_case () {
        local name="$1" gen="$2"
        local in="$TMP/z-$name.in" z="$TMP/z-$name.zst" out="$TMP/z-$name.out"
        eval "$gen" > "$in"
        # stock zstd -> zipd decompress, across levels.
        for lvl in 1 3 9 19; do
            zstd -q -f "-$lvl" -c "$in" > "$z"
            rm -f "$out"
            "$ZIPD" decompress "$z" -o "$out" --quiet
            cmp -s "$in" "$out" \
                || { echo "FAIL ($name): zstd -$lvl -> zipd mismatch" >&2; exit 1; }
        done
        # zipd -> stock zstd (raw/RLE blocks until Phase 3), both modes.
        for extra in "" "--store"; do
            rm -f "$z"
            "$ZIPD" compress "$in" -o "$z" --codec zstd $extra --quiet
            zstd -q -d -c "$z" | cmp -s - "$in" \
                || { echo "FAIL ($name): zipd zstd $extra -> zstd mismatch" >&2; exit 1; }
            rm -f "$out"
            "$ZIPD" decompress "$z" -o "$out" --quiet
            cmp -s "$in" "$out" \
                || { echo "FAIL ($name): zipd zstd self mismatch" >&2; exit 1; }
        done
        echo "ok: zstd $name"
    }
    zstd_case empty  ': '
    zstd_case small  'echo -n hello'
    zstd_case repeat 'yes a | head -c 300000'
    zstd_case binary 'head -c 300000 /dev/urandom'
    zstd_case text   'yes "the quick brown fox jumps over the lazy dog" | head -c 2000000'

    # Compression ratio check on redundant input
    echo "checking zstd compression ratio on redundant input..."
    yes "the quick brown fox" | head -c 1048576 > "$TMP/zr.in"
    "$ZIPD" compress "$TMP/zr.in" -o "$TMP/zr.zst" --codec zstd --quiet
    in_sz=$(wc -c < "$TMP/zr.in")
    out_sz=$(wc -c < "$TMP/zr.zst")
    echo "  input=$in_sz bytes, zstd=$out_sz bytes"
    if (( out_sz * 20 > in_sz )); then
        echo "FAIL: zstd compression ratio worse than 20:1 ($out_sz vs $in_sz)" >&2
        exit 1
    fi
    echo "ok: zstd ratio"

    # Concatenated frames and a skippable frame.
    echo -n "one " > "$TMP/zf1"; echo -n "two" > "$TMP/zf2"
    { zstd -q -c "$TMP/zf1"; printf '\x50\x2a\x4d\x18\x02\x00\x00\x00ab'; zstd -q -c "$TMP/zf2"; } > "$TMP/zmulti.zst"
    "$ZIPD" decompress "$TMP/zmulti.zst" -o "$TMP/zmulti.out" --quiet
    [[ "$(cat "$TMP/zmulti.out")" == "one two" ]] \
        || { echo "FAIL: zstd multi-frame mismatch" >&2; exit 1; }
    echo "ok: zstd multi-frame + skippable"

    # Multicore ZSTD compression (concatenated ZSTD frames)
    echo "checking multi-threaded zstd compression..."
    head -c 4194304 /dev/urandom > "$TMP/zmt.in"

    for THREADS in 1 2 4; do
        rm -f "$TMP/zmt.zst" "$TMP/zmt.out"
        "$ZIPD" compress "$TMP/zmt.in" -o "$TMP/zmt.zst" \
            --codec zstd --threads "$THREADS" --chunk-size 256k --quiet
        zstd -q -d -c "$TMP/zmt.zst" > "$TMP/zmt.out"
        cmp -s "$TMP/zmt.in" "$TMP/zmt.out" \
            || { echo "FAIL: zstd --threads=$THREADS zipd->zstd mismatch" >&2; exit 1; }
        rm -f "$TMP/zmt.out"
        "$ZIPD" decompress "$TMP/zmt.zst" -o "$TMP/zmt.out" --quiet
        cmp -s "$TMP/zmt.in" "$TMP/zmt.out" \
            || { echo "FAIL: zstd --threads=$THREADS zipd->zipd mismatch" >&2; exit 1; }
        echo "ok: zstd --threads=$THREADS"
    done

    # Determinism: same input + settings must produce byte-identical output.
    echo "checking multi-threaded zstd determinism..."
    "$ZIPD" compress "$TMP/zmt.in" -o "$TMP/zmt.a.zst" \
        --codec zstd --threads 4 --chunk-size 256k --quiet
    "$ZIPD" compress "$TMP/zmt.in" -o "$TMP/zmt.b.zst" \
        --codec zstd --threads 4 --chunk-size 256k --quiet
    cmp -s "$TMP/zmt.a.zst" "$TMP/zmt.b.zst" \
        || { echo "FAIL: multi-threaded zstd output is not deterministic" >&2; exit 1; }
    echo "ok: zstd determinism"

    # Auto threads (--threads 0 default) must also produce valid zstd.
    "$ZIPD" compress "$TMP/zmt.in" -o "$TMP/zmt.auto.zst" --codec zstd --quiet
    zstd -q -d -c "$TMP/zmt.auto.zst" > "$TMP/zmt.auto.out"
    cmp -s "$TMP/zmt.in" "$TMP/zmt.auto.out" \
        || { echo "FAIL: zstd --threads=auto mismatch" >&2; exit 1; }
    echo "ok: zstd --threads=auto"

    # Corruption must be rejected.
    zstd -q -c "$TMP/z-text.in" > "$TMP/zbad.zst"
    printf '\xff' | dd of="$TMP/zbad.zst" bs=1 seek=100 conv=notrunc status=none
    if "$ZIPD" decompress "$TMP/zbad.zst" -o "$TMP/zbad.out" --quiet 2>/dev/null; then
        echo "FAIL: corrupt zstd stream was accepted" >&2; exit 1
    fi
    echo "ok: zstd corruption rejected"
fi

echo "all interop tests passed"
