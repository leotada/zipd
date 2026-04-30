/**
 * Canonical Huffman tables for DEFLATE.
 *
 * Tables are built from a code-length array (as DEFLATE transmits
 * them). Decoding walks the canonical-code structure bit by bit using
 * a "first code per length" table and a sorted symbol array. This is
 * the classic puff-style decoder: simple, allocation-free per decode,
 * and easy to audit for safety.
 *
 * No `@trusted` is used; the code is fully `@safe pure nothrow @nogc`.
 */
module zipd.compressor.huffman;

import zipd.compressor.errors : Result, ErrorKind, success, failure;
import zipd.compressor.bitreader : BitReader;

@safe:

/// Maximum Huffman code length permitted by DEFLATE.
enum uint maxCodeBits = 15;

/// Maximum number of symbols any DEFLATE alphabet uses (fixed litlen).
enum uint maxSymbols = 288;

/// Sentinel returned by `decodeSymbol` on stream exhaustion or a
/// code that is not present in the table (corrupt input).
enum int decodeError = -1;

/**
 * Canonical Huffman decoder for one alphabet.
 *
 * Layout:
 *   `count[len]`  = number of symbols with code length `len` (1..15).
 *                   `count[0]` is unused.
 *   `symbol[i]`   = symbols sorted by ascending (length, symbol value).
 *
 * Storage is embedded so the decoder is self-contained and trivially
 * copyable; no scope/lifetime concerns when passing across functions.
 */
struct HuffmanDecoder
{
    uint[maxCodeBits + 1] count;
    /// Sorted symbol table; only `symbol[0 .. symbolCount]` is valid.
    ushort[maxSymbols] symbol;
    /// Number of valid entries in `symbol`.
    uint symbolCount;

    /// True if at least one code is present.
    bool empty() const pure nothrow @nogc @safe scope
    {
        foreach (c; count[1 .. $])
            if (c != 0)
                return false;
        return true;
    }

    /// Decode one symbol from `br`. Returns `decodeError` on EOF or
    /// invalid code; the caller maps that to the appropriate
    /// `ErrorKind`.
    int decodeSymbol(scope ref BitReader br) const pure nothrow @nogc @safe scope
    {
        uint code  = 0;
        uint first = 0;
        uint index = 0;
        for (uint len = 1; len <= maxCodeBits; len++)
        {
            uint bit;
            if (!br.readBits(1, bit))
                return decodeError;
            code = (code << 1) | bit;
            const c = count[len];
            if (code - first < c)
            {
                const idx = index + (code - first);
                if (idx >= symbolCount)
                    return decodeError;
                return symbol[idx];
            }
            index += c;
            first = (first + c) << 1;
        }
        return decodeError;
    }
}

/**
 * Build a `HuffmanDecoder` from a sequence of code lengths.
 *
 * `lengths[i]` is the code length of symbol `i` (0 means "unused").
 * The returned decoder is self-contained (storage is embedded).
 *
 * Returns an error if the lengths describe an over- or under-subscribed
 * code (Kraft inequality violation), with the single allowed exception
 * of a degenerate code containing zero or one symbol — DEFLATE allows
 * an "empty" or "single-symbol" distance code, so we accept it.
 */
Result!HuffmanDecoder buildHuffman(scope const(ubyte)[] lengths)
    pure nothrow @nogc @safe
{
    HuffmanDecoder dec;

    if (lengths.length > maxSymbols)
        return failure!HuffmanDecoder(ErrorKind.internal,
            "alphabet larger than maxSymbols");

    // Tally code length frequencies.
    foreach (len; lengths)
    {
        if (len > maxCodeBits)
            return failure!HuffmanDecoder(ErrorKind.corruptInput,
                "huffman code length exceeds 15");
        dec.count[len]++;
    }

    // Special case: all lengths zero. Caller decides whether that is OK.
    uint nonZero = 0;
    foreach (c; dec.count[1 .. $])
        nonZero += c;
    if (nonZero == 0)
    {
        dec.symbolCount = 0;
        return success(dec);
    }

    // Verify Kraft inequality. left starts at 1 and is doubled each
    // length; we subtract count[len] each step. The code is complete
    // iff `left` is exactly 0 at the end. DEFLATE allows
    // single-symbol codes (one symbol with length 1) but otherwise
    // requires completeness.
    int left = 1;
    for (uint len = 1; len <= maxCodeBits; len++)
    {
        left <<= 1;
        left -= cast(int) dec.count[len];
        if (left < 0)
            return failure!HuffmanDecoder(ErrorKind.corruptInput,
                "huffman over-subscribed");
    }
    if (left > 0 && nonZero != 1)
        return failure!HuffmanDecoder(ErrorKind.corruptInput,
            "huffman under-subscribed");

    // Compute offsets: first symbol slot for each length.
    uint[maxCodeBits + 1] offs;
    offs[1] = 0;
    for (uint len = 1; len < maxCodeBits; len++)
        offs[len + 1] = offs[len] + dec.count[len];

    // Place symbols in ascending order of length, then by symbol value
    // (the natural traversal order of `lengths`).
    foreach (size_t sym, len; lengths)
    {
        if (len != 0)
        {
            dec.symbol[offs[len]] = cast(ushort) sym;
            offs[len]++;
        }
    }

    dec.symbolCount = nonZero;
    return success(dec);
}

@safe unittest
{
    // Single-symbol code (allowed). Symbol 7 with length 1.
    ubyte[10] lens;
    lens[7] = 1;
    auto r = buildHuffman(lens[]);
    assert(r.ok);
    assert(!r.value.empty);
    assert(r.value.count[1] == 1);
    assert(r.value.symbol[0] == 7);
}

@safe unittest
{
    // Over-subscribed: two symbols of length 1 plus one of length 2.
    ubyte[3] lens = [1, 1, 2];
    auto r = buildHuffman(lens[]);
    assert(!r.ok);
    assert(r.error.kind == ErrorKind.corruptInput);
}

@safe unittest
{
    // Complete two-symbol code: lengths 1, 1.
    ubyte[2] lens = [1, 1];
    auto r = buildHuffman(lens[]);
    assert(r.ok);
    // Decode "01": symbol with code 0 then symbol with code 1.
    immutable ubyte[] bits = [0b10]; // LSB first: bit0=0, bit1=1
    auto br = BitReader(bits);
    assert(r.value.decodeSymbol(br) == 0);
    assert(r.value.decodeSymbol(br) == 1);
}
