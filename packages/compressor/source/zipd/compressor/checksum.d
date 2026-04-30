/**
 * CRC-32 (IEEE 802.3, gzip / zlib polynomial 0xEDB88320, reflected).
 *
 * Pure, `@safe`, `@nogc`, `nothrow`. Computes the same value as the
 * reference `gzip` trailer.
 */
module zipd.compressor.checksum;

@safe:

private immutable uint[256] crc32Table = () {
    uint[256] t;
    foreach (uint i; 0 .. 256)
    {
        uint c = i;
        foreach (_; 0 .. 8)
            c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
        t[i] = c;
    }
    return t;
}();

/// Streaming CRC-32 accumulator.
struct Crc32
{
    private uint state = 0xFFFFFFFFu;

    void put(scope const(ubyte)[] data) pure nothrow @nogc @safe
    {
        uint s = state;
        foreach (b; data)
            s = crc32Table[(s ^ b) & 0xFFu] ^ (s >> 8);
        state = s;
    }

    uint finish() const pure nothrow @nogc @safe { return state ^ 0xFFFFFFFFu; }

    void reset() pure nothrow @nogc @safe
    {
        state = 0xFFFFFFFFu;
    }
}

/// One-shot CRC-32 over `data`.
uint crc32(scope const(ubyte)[] data) pure nothrow @nogc @safe
{
    Crc32 c;
    c.put(data);
    return c.finish();
}

@safe unittest
{
    // Standard gzip/zlib test vectors.
    assert(crc32(cast(const(ubyte)[]) "") == 0x00000000);
    assert(crc32(cast(const(ubyte)[]) "a") == 0xE8B7BE43);
    assert(crc32(cast(const(ubyte)[]) "abc") == 0x352441C2);
    assert(crc32(cast(const(ubyte)[]) "123456789") == 0xCBF43926);

    // Streaming equals one-shot.
    Crc32 c;
    c.put(cast(const(ubyte)[]) "12345");
    c.put(cast(const(ubyte)[]) "6789");
    assert(c.finish() == 0xCBF43926);
}
