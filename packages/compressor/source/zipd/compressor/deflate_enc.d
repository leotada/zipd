/**
 * DEFLATE encoder — Phase 1 "store" mode only (BTYPE=00).
 *
 * Produces a valid RFC 1951 DEFLATE bitstream consisting of one or more
 * uncompressed blocks. Each stored block carries up to 65535 bytes of
 * payload. The last block has BFINAL=1.
 *
 * Phase 2 will replace this with the real DEFLATE engine (LZ77 + Huffman).
 */
module zipd.compressor.deflate_enc;

import zipd.compressor.errors : Result, ErrorKind, success, failure;

@safe:

/// Maximum payload bytes per stored DEFLATE block (RFC 1951 §3.2.4).
enum size_t maxStoredBlockBytes = 65_535;

/// Worst-case output size for `storeEncode(input)` — 5 bytes of framing
/// per stored block, plus the input itself, plus 1 byte for the final
/// block header when input is empty.
size_t storeEncodeBound(size_t inputLen) pure nothrow @nogc @safe
{
    if (inputLen == 0)
        return 5; // single empty BFINAL block
    const blocks = (inputLen + maxStoredBlockBytes - 1) / maxStoredBlockBytes;
    return inputLen + blocks * 5;
}

/// Encode `input` as a DEFLATE bitstream of stored blocks into `output`.
/// Returns the number of bytes written.
Result!size_t storeEncode(scope const(ubyte)[] input,
                         scope ubyte[] output) pure nothrow @nogc @safe
{
    const need = storeEncodeBound(input.length);
    if (output.length < need)
        return failure!size_t(ErrorKind.internal,
            "deflate store encoder output buffer too small");

    size_t inPos = 0;
    size_t outPos = 0;

    if (input.length == 0)
    {
        // One empty BFINAL stored block.
        // Header byte (3 bits = 001 LSB-first → 0x01) followed by the
        // byte-aligned LEN(=0) and NLEN(=0xFFFF).
        output[outPos++] = 0x01;
        output[outPos++] = 0x00;
        output[outPos++] = 0x00;
        output[outPos++] = 0xFF;
        output[outPos++] = 0xFF;
        return success(outPos);
    }

    while (inPos < input.length)
    {
        const remaining = input.length - inPos;
        const chunk = remaining > maxStoredBlockBytes
            ? maxStoredBlockBytes : remaining;
        const isFinal = (inPos + chunk) == input.length;

        // 3-bit block header: BFINAL (1 bit) + BTYPE (2 bits = 00).
        // LSB-first packing in a byte that is then padded to the next
        // byte boundary for stored blocks (RFC 1951 §3.2.4).
        output[outPos++] = isFinal ? 0x01 : 0x00;

        const ushort len = cast(ushort) chunk;
        const ushort nlen = cast(ushort)(~cast(uint) len & 0xFFFF);
        output[outPos++] = cast(ubyte)(len & 0xFF);
        output[outPos++] = cast(ubyte)((len >> 8) & 0xFF);
        output[outPos++] = cast(ubyte)(nlen & 0xFF);
        output[outPos++] = cast(ubyte)((nlen >> 8) & 0xFF);

        output[outPos .. outPos + chunk] = input[inPos .. inPos + chunk];
        inPos += chunk;
        outPos += chunk;
    }
    return success(outPos);
}

@safe unittest
{
    ubyte[16] outBuf;
    auto r = storeEncode([], outBuf[]);
    assert(r.ok);
    assert(r.value == 5);
    assert(outBuf[0 .. 5] == [cast(ubyte) 0x01, 0x00, 0x00, 0xFF, 0xFF]);
}

@safe unittest
{
    immutable ubyte[] data = [1, 2, 3, 4, 5];
    auto outBuf = new ubyte[storeEncodeBound(data.length)];
    auto r = storeEncode(data, outBuf);
    assert(r.ok);
    assert(r.value == 5 + data.length);
    assert(outBuf[0] == 0x01);             // BFINAL=1, BTYPE=00
    assert(outBuf[1] == 5 && outBuf[2] == 0);
    assert(outBuf[3] == 0xFA && outBuf[4] == 0xFF);
    assert(outBuf[5 .. 10] == data);
}

@safe unittest
{
    // Multi-block: 70_000 bytes → 2 blocks.
    auto data = new ubyte[70_000];
    foreach (i, ref b; data)
        b = cast(ubyte)(i & 0xFF);
    auto outBuf = new ubyte[storeEncodeBound(data.length)];
    auto r = storeEncode(data, outBuf);
    assert(r.ok);
    assert(r.value == data.length + 2 * 5);
    // First block header byte must be non-final.
    assert(outBuf[0] == 0x00);
    // Second block header is at offset 5 + 65535.
    assert(outBuf[5 + 65_535] == 0x01);
}
