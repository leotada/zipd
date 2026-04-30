/**
 * DEFLATE encoder — fixed-Huffman blocks with LZ77 back-references.
 *
 * This is the Phase 2 encoder. It operates monolithically: the entire
 * input must be supplied in one slice, and the output is written into
 * a single output slice. Phase 3 will introduce a streaming/multicore
 * variant; the on-the-wire format produced here is byte-identical to
 * what a per-chunk streamer would emit when fed the same input as one
 * piece.
 *
 * Output layout: one or more fixed-Huffman (BTYPE=01) blocks, each up
 * to `tokensPerBlock` tokens. The last block has BFINAL=1.
 *
 * 100% `@safe @nogc nothrow` (apart from heap allocations of the
 * matcher tables and token buffer, which are GC and not `@nogc`).
 */
module zipd.compressor.deflate_enc_huffman;

import zipd.compressor.errors : Result, ErrorKind, success, failure;
import zipd.compressor.bitwriter : BitWriter;
import zipd.compressor.lz77 :
    Lz77Matcher, Match, minMatch, maxMatch, windowSize;
import zipd.compressor.deflate_tables :
    lengthBase, lengthExtraBits, distanceBase, distanceExtraBits,
    numLengthCodes, numDistanceCodes, endOfBlock,
    fixedLitLenLengths, fixedLitLenCount, fixedDistLengths, fixedDistCount;

@safe:

/// Number of tokens accumulated before flushing a fixed-Huffman block.
/// Smaller blocks mean more 3-bit headers but tighter incremental
/// flushing. 16 K tokens is a reasonable middle ground.
enum size_t tokensPerBlock = 16 * 1024;

/// Worst-case output size for `deflateEncode(input)`.
/// 9 bits per literal in fixed-Huffman is the upper bound; round up
/// generously and add room for headers and a trailing empty block.
size_t deflateEncodeBound(size_t inputLen) pure nothrow @nogc @safe
{
    return inputLen + inputLen / 8 + 64;
}

/// Encode `input` as a DEFLATE bitstream (one or more fixed-Huffman
/// blocks) into `output`. Returns the number of bytes written.
Result!size_t deflateEncode(const(ubyte)[] input,
                            scope ubyte[] output, uint level) @safe
{
    if (level == 0)
        return failure!size_t(ErrorKind.invalidArgs,
            "level 0 means store; call storeEncode instead");
    if (output.length < deflateEncodeBound(input.length))
        return failure!size_t(ErrorKind.internal,
            "deflate encoder output buffer too small");

    scope BitWriter bw = BitWriter(output);

    // Empty input: emit a single empty fixed-Huffman block (BFINAL=1,
    // BTYPE=01, EOB). 3 + 7 = 10 bits, padded to 16.
    if (input.length == 0)
    {
        if (!writeBitsChecked(bw, 0b011, 3))      // BFINAL=1, BTYPE=01 (LSB-first)
            return failure!size_t(ErrorKind.internal, "bitwriter overflow");
        if (!emitFixedSymbol(bw, endOfBlock))
            return failure!size_t(ErrorKind.internal, "bitwriter overflow");
        const f = bw.flushToByteBoundary();
        if (!f.ok)
            return failure!size_t(f.error.kind, f.error.message);
        return success(bw.bytesFlushed);
    }

    scope Lz77Matcher matcher;
    matcher.init(input, level);

    scope Token[] tokens = new Token[tokensPerBlock];
    size_t tokCount = 0;
    size_t pos = 0;

    while (pos < input.length)
    {
        Match m;
        if (pos + minMatch <= input.length)
        {
            m = matcher.findLongest(pos);
        }
        if (m.length >= minMatch)
        {
            tokens[tokCount++] = Token.match(m.length, m.distance);
            // Insert hashes for skipped positions so future matches see them.
            const end = pos + m.length;
            foreach (i; pos + 1 .. end)
            {
                if (i + minMatch <= input.length)
                    matcher.insert(i);
            }
            pos = end;
        }
        else
        {
            tokens[tokCount++] = Token.literal(input[pos]);
            pos++;
        }
        if (tokCount == tokens.length)
        {
            const isFinal = (pos == input.length);
            auto r = emitFixedBlock(bw, tokens[0 .. tokCount], isFinal);
            if (!r.ok)
                return failure!size_t(r.error.kind, r.error.message);
            tokCount = 0;
            if (isFinal)
                break;
        }
    }

    if (tokCount > 0 || pos == 0)
    {
        // Flush remaining tokens (or the degenerate "no tokens" case
        // where we still need a final block).
        auto r = emitFixedBlock(bw, tokens[0 .. tokCount], true);
        if (!r.ok)
            return failure!size_t(r.error.kind, r.error.message);
    }
    else if (pos == input.length && tokCount == 0)
    {
        // We emitted the final block already inside the loop. Nothing
        // more to do.
    }

    const f = bw.flushToByteBoundary();
    if (!f.ok)
        return failure!size_t(f.error.kind, f.error.message);
    return success(bw.bytesFlushed);
}

// ---------------------------------------------------------------- //
// Tokens and block emission

private struct Token
{
    // dist == 0 means literal; lit holds the byte. Otherwise this is a
    // (length, distance) match.
    ushort lenOrLit;
    ushort dist;

    static Token literal(ubyte b) pure nothrow @nogc @safe
    {
        Token t;
        t.lenOrLit = b;
        t.dist = 0;
        return t;
    }

    static Token match(uint length, uint distance) pure nothrow @nogc @safe
    {
        Token t;
        t.lenOrLit = cast(ushort) length;
        t.dist = cast(ushort) distance;
        return t;
    }

    bool isLiteral() const pure nothrow @nogc @safe scope { return dist == 0; }
}

private Result!size_t emitFixedBlock(scope ref BitWriter bw,
                                     scope const(Token)[] tokens,
                                     bool isFinal) @safe
{
    // 3-bit header: BFINAL, BTYPE=01. LSB-first encoding.
    const uint header = (isFinal ? 1u : 0u) | (0b01u << 1);
    if (!writeBitsChecked(bw, header, 3))
        return failure!size_t(ErrorKind.internal, "bitwriter overflow");

    foreach (ref t; tokens)
    {
        if (t.isLiteral)
        {
            if (!emitFixedSymbol(bw, t.lenOrLit))
                return failure!size_t(ErrorKind.internal, "bitwriter overflow");
        }
        else
        {
            // Length symbol + extra bits.
            const uint lc = lengthCodeOf[t.lenOrLit];
            const uint lExtraBits = lengthExtraBits[lc];
            const uint lExtraVal  = cast(uint) t.lenOrLit - lengthBase[lc];
            const uint lSym       = 257u + lc;
            if (!emitFixedSymbol(bw, cast(int) lSym))
                return failure!size_t(ErrorKind.internal, "bitwriter overflow");
            if (lExtraBits != 0)
            {
                if (!writeBitsChecked(bw, lExtraVal, lExtraBits))
                    return failure!size_t(ErrorKind.internal, "bitwriter overflow");
            }
            // Distance symbol (5-bit reversed) + extra bits.
            const uint dc = distanceCodeOf[t.dist];
            const uint dExtraBits = distanceExtraBits[dc];
            const uint dExtraVal  = cast(uint) t.dist - distanceBase[dc];
            const uint distRev    = bitReverse(dc, 5);
            if (!writeBitsChecked(bw, distRev, 5))
                return failure!size_t(ErrorKind.internal, "bitwriter overflow");
            if (dExtraBits != 0)
            {
                if (!writeBitsChecked(bw, dExtraVal, dExtraBits))
                    return failure!size_t(ErrorKind.internal, "bitwriter overflow");
            }
        }
    }

    if (!emitFixedSymbol(bw, endOfBlock))
        return failure!size_t(ErrorKind.internal, "bitwriter overflow");
    return success(cast(size_t) 0);
}

private bool emitFixedSymbol(scope ref BitWriter bw, int sym) @safe
{
    const e = fixedLitLenEnc[sym];
    return writeBitsChecked(bw, e.code, e.bits);
}

private bool writeBitsChecked(scope ref BitWriter bw, uint value, uint nBits) @safe
{
    auto r = bw.writeBits(value, nBits);
    return r.ok;
}

private uint bitReverse(uint v, uint nBits) pure nothrow @nogc @safe
{
    uint r = 0;
    foreach (i; 0 .. nBits)
    {
        r = (r << 1) | (v & 1);
        v >>= 1;
    }
    return r;
}

// ---------------------------------------------------------------- //
// CTFE-built emission tables

private struct FixedSym
{
    uint code;  // bit-reversed code, ready to emit LSB-first
    uint bits;  // 7..9
}

private immutable FixedSym[fixedLitLenCount] fixedLitLenEnc = () {
    FixedSym[fixedLitLenCount] t;
    // Build canonical codes from fixedLitLenLengths.
    uint[16] blCount;
    foreach (l; fixedLitLenLengths)
        blCount[l]++;
    uint[16] nextCode;
    uint code = 0;
    blCount[0] = 0;
    for (uint bits = 1; bits <= 15; bits++)
    {
        code = (code + blCount[bits - 1]) << 1;
        nextCode[bits] = code;
    }
    foreach (sym; 0 .. fixedLitLenCount)
    {
        const len = fixedLitLenLengths[sym];
        if (len != 0)
        {
            const c = nextCode[len];
            nextCode[len]++;
            // Reverse bits for LSB-first emission.
            uint r = 0;
            uint v = c;
            foreach (_; 0 .. len) { r = (r << 1) | (v & 1); v >>= 1; }
            t[sym].code = r;
            t[sym].bits = len;
        }
    }
    return t;
}();

/// `lengthCodeOf[len]` for `len` in `minMatch .. maxMatch` (3..258)
/// → length code in 0..28.
private immutable ubyte[maxMatch + 1] lengthCodeOf = () {
    ubyte[maxMatch + 1] t;
    foreach (lc; 0 .. numLengthCodes)
    {
        const base = lengthBase[lc];
        const span = (lc + 1 < numLengthCodes
            ? lengthBase[lc + 1] : maxMatch + 1) - base;
        foreach (i; 0 .. span)
            t[base + i] = cast(ubyte) lc;
    }
    return t;
}();

/// `distanceCodeOf[dist]` for `dist` in `1 .. windowSize` (1..32768)
/// → distance code in 0..29.
private immutable ubyte[windowSize + 1] distanceCodeOf = () {
    ubyte[windowSize + 1] t;
    foreach (dc; 0 .. numDistanceCodes)
    {
        const base = distanceBase[dc];
        const span = (dc + 1 < numDistanceCodes
            ? distanceBase[dc + 1] : windowSize + 1) - base;
        foreach (i; 0 .. span)
            t[base + i] = cast(ubyte) dc;
    }
    return t;
}();

// ---------------------------------------------------------------- //
// Tests

@safe unittest
{
    // Empty input → minimal valid stream (we built an empty fixed block).
    auto outBuf = new ubyte[deflateEncodeBound(0)];
    auto r = deflateEncode([], outBuf, 6);
    assert(r.ok);
    assert(r.value >= 1);
}

@safe unittest
{
    import zipd.compressor.deflate_dec : deflateDecode;

    immutable ubyte[] msg = cast(immutable(ubyte)[])
        "the quick brown fox jumps over the lazy dog";
    auto enc = new ubyte[deflateEncodeBound(msg.length)];
    auto er = deflateEncode(msg, enc, 6);
    assert(er.ok);

    auto dec = new ubyte[msg.length];
    auto dr = deflateDecode(enc[0 .. er.value], dec);
    assert(dr.ok);
    assert(dr.value.produced == msg.length);
    assert(dec[0 .. msg.length] == msg);
}

@safe unittest
{
    import zipd.compressor.deflate_dec : deflateDecode;

    // Highly redundant input — expect significant compression.
    auto msg = new ubyte[64 * 1024];
    foreach (i, ref b; msg)
        b = cast(ubyte)(i & 0x07);
    auto enc = new ubyte[deflateEncodeBound(msg.length)];
    auto er = deflateEncode(msg, enc, 6);
    assert(er.ok);
    assert(er.value < msg.length / 4); // should compress dramatically

    auto dec = new ubyte[msg.length];
    auto dr = deflateDecode(enc[0 .. er.value], dec);
    assert(dr.ok);
    assert(dec == msg);
}

@safe unittest
{
    import zipd.compressor.deflate_dec : deflateDecode;

    // Multi-block input.
    auto msg = new ubyte[200 * 1024];
    foreach (i, ref b; msg)
        b = cast(ubyte)(i * 31 & 0xFF);
    auto enc = new ubyte[deflateEncodeBound(msg.length)];
    auto er = deflateEncode(msg, enc, 6);
    assert(er.ok);
    auto dec = new ubyte[msg.length];
    auto dr = deflateDecode(enc[0 .. er.value], dec);
    assert(dr.ok);
    assert(dec == msg);
}
