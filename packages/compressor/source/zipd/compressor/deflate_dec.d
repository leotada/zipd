/**
 * DEFLATE decoder.
 *
 * Supports all three block types defined by RFC 1951:
 *   BTYPE=00  stored
 *   BTYPE=01  fixed Huffman
 *   BTYPE=10  dynamic Huffman
 *
 * The decoder is bit-buffered LSB-first via `BitReader`, and writes
 * the inflated stream into a caller-provided slice. If the slice
 * fills before the BFINAL block ends, decoding fails with
 * `ErrorKind.internal` (caller must retry with a larger buffer).
 *
 * The compressor module body itself is `@safe`. The fixed-Huffman
 * tables are built once at module init; the initializer is the only
 * `@trusted` point in this file (it writes module-private storage
 * before any decode runs).
 */
module zipd.compressor.deflate_dec;

import zipd.compressor.errors : Result, ErrorKind, success, failure;
import zipd.compressor.bitreader : BitReader;
import zipd.compressor.huffman :
    HuffmanDecoder, buildHuffman, decodeError, maxCodeBits;
import zipd.compressor.deflate_tables;

@safe:

/// Result of a DEFLATE decode operation.
struct DeflateDecoded
{
    /// Bytes consumed from the input slice.
    size_t consumed;
    /// Bytes produced into the output slice.
    size_t produced;
}

/// Decode a complete DEFLATE bitstream from `input` into `output`.
/// Returns the number of bytes consumed from `input` and produced
/// into `output`.
Result!DeflateDecoded deflateDecode(scope const(ubyte)[] input,
                                    scope ubyte[] output) nothrow @safe
{
    auto br = BitReader(input);
    size_t outPos = 0;

    while (true)
    {
        uint hdr;
        if (!br.readBits(3, hdr))
            return failure!DeflateDecoded(ErrorKind.corruptInput,
                "deflate header truncated");
        const bool bfinal = (hdr & 1) != 0;
        const uint  btype  = (hdr >> 1) & 0b11;

        if (btype == 0b00)
        {
            auto r = decodeStored(br, output, outPos);
            if (!r.ok)
                return failure!DeflateDecoded(r.error.kind, r.error.message);
        }
        else if (btype == 0b01)
        {
            auto fix = fixedTables();
            auto r = decodeHuffman(br, output, outPos,
                fix.litlen, fix.dist);
            if (!r.ok)
                return failure!DeflateDecoded(r.error.kind, r.error.message);
        }
        else if (btype == 0b10)
        {
            auto r = decodeDynamic(br, output, outPos);
            if (!r.ok)
                return failure!DeflateDecoded(r.error.kind, r.error.message);
        }
        else
        {
            return failure!DeflateDecoded(ErrorKind.corruptInput,
                "reserved DEFLATE block type");
        }

        if (bfinal)
            break;
    }

    return success(DeflateDecoded(br.bytesConsumed, outPos));
}

// ---------------------------------------------------------------- //
// Block decoders

private struct Unit { }

private Result!Unit decodeStored(scope ref BitReader br,
                                 scope ubyte[] output, ref size_t outPos)
    pure nothrow @nogc @safe
{
    br.alignToByte();
    ubyte[4] hdr;
    if (!br.readBytes(hdr[]))
        return failure!Unit(ErrorKind.corruptInput,
            "stored block header truncated");
    const uint len  = cast(uint) hdr[0] | (cast(uint) hdr[1] << 8);
    const uint nlen = cast(uint) hdr[2] | (cast(uint) hdr[3] << 8);
    if ((len ^ nlen) != 0xFFFF)
        return failure!Unit(ErrorKind.corruptInput,
            "stored block LEN/NLEN mismatch");
    if (outPos + len > output.length)
        return failure!Unit(ErrorKind.internal,
            "decode output buffer overflow");
    if (!br.readBytes(output[outPos .. outPos + len]))
        return failure!Unit(ErrorKind.corruptInput,
            "stored block payload truncated");
    outPos += len;
    return success(Unit.init);
}

private Result!Unit decodeHuffman(scope ref BitReader br,
                                  scope ubyte[] output, ref size_t outPos,
                                  scope ref const HuffmanDecoder litlen,
                                  scope ref const HuffmanDecoder dist)
    pure nothrow @nogc @safe
{
    while (true)
    {
        const sym = litlen.decodeSymbol(br);
        if (sym < 0)
            return failure!Unit(ErrorKind.corruptInput,
                "litlen decode failed");
        if (sym < 256)
        {
            if (outPos >= output.length)
                return failure!Unit(ErrorKind.internal,
                    "decode output buffer overflow");
            output[outPos++] = cast(ubyte) sym;
            continue;
        }
        if (sym == endOfBlock)
            return success(Unit.init);
        // sym in 257..285
        const uint lcode = cast(uint) sym - 257;
        if (lcode >= numLengthCodes)
            return failure!Unit(ErrorKind.corruptInput,
                "invalid length code");
        uint extra = 0;
        const uint lExtraBits = lengthExtraBits[lcode];
        if (lExtraBits != 0 && !br.readBits(lExtraBits, extra))
            return failure!Unit(ErrorKind.corruptInput,
                "length extra bits truncated");
        const uint matchLen = lengthBase[lcode] + extra;

        const dsym = dist.decodeSymbol(br);
        if (dsym < 0 || dsym >= cast(int) numDistanceCodes)
            return failure!Unit(ErrorKind.corruptInput,
                "distance code invalid");
        uint dExtra = 0;
        const uint dExtraBits = distanceExtraBits[dsym];
        if (dExtraBits != 0 && !br.readBits(dExtraBits, dExtra))
            return failure!Unit(ErrorKind.corruptInput,
                "distance extra bits truncated");
        const uint matchDist = distanceBase[dsym] + dExtra;

        if (matchDist == 0 || matchDist > outPos)
            return failure!Unit(ErrorKind.corruptInput,
                "distance points before output start");
        if (outPos + matchLen > output.length)
            return failure!Unit(ErrorKind.internal,
                "decode output buffer overflow");

        // LZ77 copy with possible overlap. If length > distance, copy
        // byte-by-byte so the source slides as we write.
        const size_t srcStart = outPos - matchDist;
        if (matchLen <= matchDist)
        {
            output[outPos .. outPos + matchLen]
                = output[srcStart .. srcStart + matchLen];
        }
        else
        {
            foreach (i; 0 .. matchLen)
                output[outPos + i] = output[srcStart + i];
        }
        outPos += matchLen;
    }
}

private Result!Unit decodeDynamic(scope ref BitReader br,
                                  scope ubyte[] output, ref size_t outPos)
    pure nothrow @nogc @safe
{
    uint hlit, hdist, hclen;
    if (!br.readBits(5, hlit) || !br.readBits(5, hdist)
        || !br.readBits(4, hclen))
        return failure!Unit(ErrorKind.corruptInput,
            "dynamic header truncated");
    const uint nLit  = hlit  + 257;
    const uint nDist = hdist + 1;
    const uint nCL   = hclen + 4;
    if (nLit > 286 || nDist > 30)
        return failure!Unit(ErrorKind.corruptInput,
            "dynamic alphabet sizes out of range");

    // Read code-length-code lengths in their permuted order.
    ubyte[19] clLengths;
    foreach (i; 0 .. nCL)
    {
        uint v;
        if (!br.readBits(3, v))
            return failure!Unit(ErrorKind.corruptInput,
                "code-length code lengths truncated");
        clLengths[codeLengthOrder[i]] = cast(ubyte) v;
    }

    ushort[19] clSyms;
    auto clBuild = buildHuffman(clLengths[]);
    if (!clBuild.ok)
        return failure!Unit(clBuild.error.kind, clBuild.error.message);
    const HuffmanDecoder clDec = clBuild.value;

    // Decode the combined code-length sequence for litlen + dist.
    ubyte[286 + 30] combined;
    const uint total = nLit + nDist;
    uint i = 0;
    while (i < total)
    {
        const sym = clDec.decodeSymbol(br);
        if (sym < 0)
            return failure!Unit(ErrorKind.corruptInput,
                "code-length decode failed");
        if (sym < 16)
        {
            combined[i++] = cast(ubyte) sym;
        }
        else if (sym == 16)
        {
            uint extra;
            if (!br.readBits(2, extra))
                return failure!Unit(ErrorKind.corruptInput,
                    "code-length extra bits truncated");
            const uint repeat = 3 + extra;
            if (i == 0 || i + repeat > total)
                return failure!Unit(ErrorKind.corruptInput,
                    "code-length repeat out of range");
            const ubyte prev = combined[i - 1];
            foreach (_; 0 .. repeat)
                combined[i++] = prev;
        }
        else if (sym == 17)
        {
            uint extra;
            if (!br.readBits(3, extra))
                return failure!Unit(ErrorKind.corruptInput,
                    "code-length extra bits truncated");
            const uint repeat = 3 + extra;
            if (i + repeat > total)
                return failure!Unit(ErrorKind.corruptInput,
                    "code-length repeat out of range");
            foreach (_; 0 .. repeat)
                combined[i++] = 0;
        }
        else if (sym == 18)
        {
            uint extra;
            if (!br.readBits(7, extra))
                return failure!Unit(ErrorKind.corruptInput,
                    "code-length extra bits truncated");
            const uint repeat = 11 + extra;
            if (i + repeat > total)
                return failure!Unit(ErrorKind.corruptInput,
                    "code-length repeat out of range");
            foreach (_; 0 .. repeat)
                combined[i++] = 0;
        }
        else
        {
            return failure!Unit(ErrorKind.corruptInput,
                "invalid code-length symbol");
        }
    }

    ushort[286] litlenSyms;
    auto litBuild = buildHuffman(combined[0 .. nLit]);
    if (!litBuild.ok)
        return failure!Unit(litBuild.error.kind, litBuild.error.message);

    ushort[30] distSyms;
    auto distBuild = buildHuffman(combined[nLit .. nLit + nDist]);
    if (!distBuild.ok)
        return failure!Unit(distBuild.error.kind, distBuild.error.message);

    return decodeHuffman(br, output, outPos, litBuild.value, distBuild.value);
}

// ---------------------------------------------------------------- //
// Fixed-Huffman tables, built at compile time via CTFE.

private immutable HuffmanDecoder fixedLitLenDecoder = () {
    auto r = buildHuffman(fixedLitLenLengths[]);
    assert(r.ok, "fixed litlen Huffman build failed at CTFE");
    return r.value;
}();
private immutable HuffmanDecoder fixedDistDecoder = () {
    auto r = buildHuffman(fixedDistLengths[]);
    assert(r.ok, "fixed dist Huffman build failed at CTFE");
    return r.value;
}();

private struct FixedTables
{
    HuffmanDecoder litlen;
    HuffmanDecoder dist;
}

private FixedTables fixedTables() pure nothrow @nogc @safe
{
    return FixedTables(fixedLitLenDecoder, fixedDistDecoder);
}


// ---------------------------------------------------------------- //
// Tests

@safe unittest
{
    // Empty stored stream → empty output.
    immutable ubyte[] empty = [0x01, 0x00, 0x00, 0xFF, 0xFF];
    ubyte[16] outBuf;
    auto r = deflateDecode(empty, outBuf[]);
    assert(r.ok);
    assert(r.value.consumed == 5);
    assert(r.value.produced == 0);
}

@safe unittest
{
    import zipd.compressor.deflate_enc : storeEncode, storeEncodeBound;
    immutable ubyte[] data = [10, 20, 30, 40, 50];
    auto enc = new ubyte[storeEncodeBound(data.length)];
    auto e = storeEncode(data, enc);
    assert(e.ok);
    auto dec = new ubyte[data.length];
    auto d = deflateDecode(enc[0 .. e.value], dec);
    assert(d.ok);
    assert(d.value.produced == data.length);
    assert(dec == data);
}

@safe unittest
{
    // Empty fixed-Huffman block: BFINAL=1, BTYPE=01, then EOB (sym 256 =
    // 7-bit code 0000000). Bits LSB-first: 1, 1, 0, then 0000000.
    // Packed: byte0=0b00000011, byte1=0b00000000.
    immutable ubyte[] block = [0x03, 0x00];
    ubyte[16] outBuf;
    auto r = deflateDecode(block, outBuf[]);
    assert(r.ok);
    assert(r.value.produced == 0);
}
