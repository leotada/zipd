/**
 * ZSTD frame, block and skippable-frame framing (RFC 8878 §3.1).
 *
 * Pure parsing / serialization of the fixed-layout pieces. No entropy
 * coding happens here.
 */
module zipd.compressor.zstd_frame;

import zipd.compressor.errors : Result, ErrorKind, success, failure;

@safe:

/// Frame magic number, 0xFD2FB528 (bytes 28 B5 2F FD).
enum uint zstdMagic = 0xFD2FB528u;
/// Skippable frame magic range 0x184D2A50 .. 0x184D2A5F.
enum uint zstdSkippableMagicBase = 0x184D2A50u;
enum uint zstdSkippableMagicMask = 0xFFFFFFF0u;
/// Largest block size (decoded or encoded), 128 KiB.
enum size_t zstdBlockMaxSize = 128 * 1024;
/// Default decoder-side cap on the window size (128 MiB).
enum ulong zstdDefaultMaxWindow = 128UL * 1024 * 1024;
/// Smallest legal window size.
enum ulong zstdMinWindow = 1024;

/// Block type from the 2-bit field of the block header.
enum ZstdBlockType : ubyte
{
    raw        = 0,
    rle        = 1,
    compressed = 2,
    reserved   = 3,
}

/// Parsed frame header.
struct ZstdFrameHeader
{
    /// Window size in bytes (== contentSize when singleSegment).
    ulong windowSize;
    /// Frame_Content_Size, valid iff `hasContentSize`.
    ulong contentSize;
    bool  hasContentSize;
    bool  singleSegment;
    bool  hasChecksum;
    uint  dictId;
    /// Total header length in bytes, including the 4-byte magic.
    size_t headerSize;
}

/// Parsed 3-byte block header.
struct ZstdBlockHeader
{
    bool           lastBlock;
    ZstdBlockType  type;
    /// For raw/compressed: payload bytes. For RLE: regenerated size.
    uint           blockSize;
}

// ------------------------------------------------------------------ //
// Little-endian helpers

/// Read a little-endian value of `n` (1..8) bytes. Caller checks length.
ulong readLe(scope const(ubyte)[] p, size_t n) pure nothrow @nogc
{
    ulong v = 0;
    foreach (i; 0 .. n)
        v |= cast(ulong) p[i] << (8 * i);
    return v;
}

/// Write the low `n` (1..8) bytes of `v` little-endian. Caller checks length.
void writeLe(scope ubyte[] p, ulong v, size_t n) pure nothrow @nogc
{
    foreach (i; 0 .. n)
        p[i] = cast(ubyte)((v >> (8 * i)) & 0xFF);
}

// ------------------------------------------------------------------ //
// Magic detection

/// True if `data` begins with the ZSTD frame magic.
bool isZstdFrameMagic(scope const(ubyte)[] data) pure nothrow @nogc
{
    return data.length >= 4 && readLe(data, 4) == zstdMagic;
}

/// True if `data` begins with a skippable-frame magic.
bool isZstdSkippableMagic(scope const(ubyte)[] data) pure nothrow @nogc
{
    return data.length >= 4
        && (readLe(data, 4) & zstdSkippableMagicMask) == zstdSkippableMagicBase;
}

/// True if `data` begins with either kind of ZSTD frame.
bool isZstdMagic(scope const(ubyte)[] data) pure nothrow @nogc
{
    return isZstdFrameMagic(data) || isZstdSkippableMagic(data);
}

// ------------------------------------------------------------------ //
// Window descriptor

private ulong windowFromDescriptor(ubyte d) pure nothrow @nogc
{
    const base = 1UL << (10 + (d >> 3));
    return base + (base >> 3) * (d & 7);
}

/// Smallest window descriptor byte describing a window >= `size`.
Result!ubyte windowDescriptorFor(ulong size) pure nothrow @nogc
{
    foreach (uint e; 0 .. 32)
        foreach (uint m; 0 .. 8)
        {
            ubyte d = cast(ubyte)((e << 3) | m);
            if (windowFromDescriptor(d) >= size)
                return success(d);
        }
    return failure!ubyte(ErrorKind.invalidArgs, "window size too large");
}

// ------------------------------------------------------------------ //
// Frame header

/// Parse a frame header at the start of `src`. `maxWindow` bounds the
/// window the caller is willing to allocate.
Result!ZstdFrameHeader parseZstdFrameHeader(scope const(ubyte)[] src,
    ulong maxWindow = zstdDefaultMaxWindow) pure nothrow @nogc
{
    if (src.length < 5)
        return failure!ZstdFrameHeader(ErrorKind.corruptInput,
            "truncated zstd frame header");
    if (readLe(src, 4) != zstdMagic)
        return failure!ZstdFrameHeader(ErrorKind.corruptInput,
            "bad zstd magic number");

    const fhd = src[4];
    const fcsFlag = fhd >> 6;
    const single = ((fhd >> 5) & 1) != 0;
    if ((fhd & 0x08) != 0)
        return failure!ZstdFrameHeader(ErrorKind.corruptInput,
            "zstd reserved header bit set");
    const hasChecksum = ((fhd >> 2) & 1) != 0;
    const didFlag = fhd & 3;

    static immutable ubyte[4] didSize = [0, 1, 2, 4];
    static immutable ubyte[4] fcsSizeMulti = [0, 2, 4, 8];
    const dSz = didSize[didFlag];
    const fcsSz = (fcsFlag == 0 && single) ? 1 : fcsSizeMulti[fcsFlag];
    const winSz = single ? 0 : 1;

    const need = 5 + winSz + dSz + fcsSz;
    if (src.length < need)
        return failure!ZstdFrameHeader(ErrorKind.corruptInput,
            "truncated zstd frame header");

    ZstdFrameHeader h;
    h.singleSegment = single;
    h.hasChecksum = hasChecksum;
    h.headerSize = need;
    size_t pos = 5;

    ulong window = 0;
    if (!single)
        window = windowFromDescriptor(src[pos++]);
    if (dSz > 0)
    {
        h.dictId = cast(uint) readLe(src[pos .. $], dSz);
        pos += dSz;
    }
    if (fcsSz > 0)
    {
        ulong fcs = readLe(src[pos .. $], fcsSz);
        if (fcsSz == 2)
            fcs += 256;
        h.contentSize = fcs;
        h.hasContentSize = true;
    }
    if (single)
        window = h.contentSize;
    h.windowSize = window;

    if (window > maxWindow)
        return failure!ZstdFrameHeader(ErrorKind.unsupported,
            "zstd window size exceeds decoder limit");
    return success(h);
}

/// Serialize a frame header (including magic) into `dst`.
///
/// Honors `singleSegment`, `hasContentSize`, `hasChecksum`. Dictionary
/// IDs are not supported by the writer. Returns bytes written.
Result!size_t writeZstdFrameHeader(scope ubyte[] dst,
    in ZstdFrameHeader h) pure nothrow @nogc
{
    if (h.dictId != 0)
        return failure!size_t(ErrorKind.unsupported,
            "zstd dictionaries are not supported");
    if (h.singleSegment && !h.hasContentSize)
        return failure!size_t(ErrorKind.invalidArgs,
            "single-segment frame requires a content size");

    ubyte fcsFlag = 0;
    size_t fcsSz = 0;
    if (h.hasContentSize)
    {
        const c = h.contentSize;
        if (h.singleSegment && c < 256)
        {
            fcsFlag = 0; fcsSz = 1;
        }
        else if (c >= 256 && c < 256 + 65536)
        {
            fcsFlag = 1; fcsSz = 2;
        }
        else if (c <= uint.max)
        {
            fcsFlag = 2; fcsSz = 4;
        }
        else
        {
            fcsFlag = 3; fcsSz = 8;
        }
    }

    ubyte winDesc = 0;
    if (!h.singleSegment)
    {
        auto w = windowDescriptorFor(h.windowSize < zstdMinWindow
            ? zstdMinWindow : h.windowSize);
        if (!w.ok)
            return failure!size_t(w.error.kind, w.error.message);
        winDesc = w.value;
    }

    const need = 5 + (h.singleSegment ? 0 : 1) + fcsSz;
    if (dst.length < need)
        return failure!size_t(ErrorKind.internal,
            "zstd frame header destination too small");

    writeLe(dst, zstdMagic, 4);
    dst[4] = cast(ubyte)((fcsFlag << 6)
        | (h.singleSegment ? 0x20 : 0)
        | (h.hasChecksum ? 0x04 : 0));
    size_t pos = 5;
    if (!h.singleSegment)
        dst[pos++] = winDesc;
    if (fcsSz > 0)
    {
        writeLe(dst[pos .. $], h.contentSize - (fcsSz == 2 ? 256 : 0), fcsSz);
        pos += fcsSz;
    }
    return success(pos);
}

// ------------------------------------------------------------------ //
// Block header

/// Size of a block header in bytes.
enum size_t zstdBlockHeaderSize = 3;

/// Parse a 3-byte block header.
Result!ZstdBlockHeader parseZstdBlockHeader(scope const(ubyte)[] src)
    pure nothrow @nogc
{
    if (src.length < zstdBlockHeaderSize)
        return failure!ZstdBlockHeader(ErrorKind.corruptInput,
            "truncated zstd block header");
    const v = cast(uint) readLe(src, 3);
    ZstdBlockHeader b;
    b.lastBlock = (v & 1) != 0;
    b.type = cast(ZstdBlockType)((v >> 1) & 3);
    b.blockSize = v >> 3;
    if (b.type == ZstdBlockType.reserved)
        return failure!ZstdBlockHeader(ErrorKind.corruptInput,
            "reserved zstd block type");
    if (b.blockSize > zstdBlockMaxSize)
        return failure!ZstdBlockHeader(ErrorKind.corruptInput,
            "zstd block exceeds 128 KiB");
    return success(b);
}

/// Serialize a 3-byte block header.
Result!size_t writeZstdBlockHeader(scope ubyte[] dst,
    in ZstdBlockHeader b) pure nothrow @nogc
{
    if (dst.length < zstdBlockHeaderSize)
        return failure!size_t(ErrorKind.internal,
            "zstd block header destination too small");
    if (b.type == ZstdBlockType.reserved || b.blockSize > zstdBlockMaxSize)
        return failure!size_t(ErrorKind.invalidArgs,
            "invalid zstd block header");
    const v = (b.blockSize << 3) | (cast(uint) b.type << 1)
        | (b.lastBlock ? 1u : 0u);
    writeLe(dst, v, 3);
    return success(zstdBlockHeaderSize);
}

// ------------------------------------------------------------------ //
// Skippable frames and checksum trailer

/// Validate a skippable frame at the start of `src`; returns its total
/// length (8-byte header + payload).
Result!size_t parseZstdSkippableFrame(scope const(ubyte)[] src)
    pure nothrow @nogc
{
    if (!isZstdSkippableMagic(src))
        return failure!size_t(ErrorKind.corruptInput,
            "not a zstd skippable frame");
    if (src.length < 8)
        return failure!size_t(ErrorKind.corruptInput,
            "truncated zstd skippable frame header");
    const size = readLe(src[4 .. $], 4);
    const total = 8 + size;
    if (total > src.length)
        return failure!size_t(ErrorKind.corruptInput,
            "truncated zstd skippable frame");
    return success(cast(size_t) total);
}

/// Write a skippable frame with `payload` (magic nibble 0..15).
Result!size_t writeZstdSkippableFrame(scope ubyte[] dst,
    scope const(ubyte)[] payload, uint nibble = 0) pure nothrow @nogc
{
    if (nibble > 15 || payload.length > uint.max)
        return failure!size_t(ErrorKind.invalidArgs,
            "invalid skippable frame");
    if (dst.length < 8 + payload.length)
        return failure!size_t(ErrorKind.internal,
            "skippable frame destination too small");
    writeLe(dst, zstdSkippableMagicBase + nibble, 4);
    writeLe(dst[4 .. $], payload.length, 4);
    dst[8 .. 8 + payload.length] = payload[];
    return success(8 + payload.length);
}

/// Content checksum trailer length.
enum size_t zstdChecksumSize = 4;

/// Read the 4-byte checksum trailer.
Result!uint parseZstdChecksum(scope const(ubyte)[] src) pure nothrow @nogc
{
    if (src.length < zstdChecksumSize)
        return failure!uint(ErrorKind.corruptInput,
            "truncated zstd content checksum");
    return success(cast(uint) readLe(src, 4));
}

/// Write the 4-byte checksum trailer.
Result!size_t writeZstdChecksum(scope ubyte[] dst, uint checksum)
    pure nothrow @nogc
{
    if (dst.length < zstdChecksumSize)
        return failure!size_t(ErrorKind.internal,
            "zstd checksum destination too small");
    writeLe(dst, checksum, 4);
    return success(zstdChecksumSize);
}

// ------------------------------------------------------------------ //
// Tests

@safe unittest
{
    // Known header produced by `zstd`: single segment, FCS=5, checksum.
    // 28 B5 2F FD | FHD=0x24 (single seg + checksum, fcs flag 0) | 05
    immutable ubyte[] hdr = [0x28, 0xB5, 0x2F, 0xFD, 0x24, 0x05];
    auto r = parseZstdFrameHeader(hdr);
    assert(r.ok);
    assert(r.value.singleSegment && r.value.hasChecksum);
    assert(r.value.hasContentSize && r.value.contentSize == 5);
    assert(r.value.windowSize == 5);
    assert(r.value.headerSize == 6);
}

@safe unittest
{
    // Real frame emitted by `zstd -c` for the input "abc".
    import zipd.compressor.xxhash : xxh64Low32;
    immutable ubyte[] frame = [0x28, 0xB5, 0x2F, 0xFD, 0x24, 0x03, 0x19,
        0x00, 0x00, 0x61, 0x62, 0x63, 0x99, 0x09, 0x77, 0xAD];
    auto h = parseZstdFrameHeader(frame);
    assert(h.ok && h.value.contentSize == 3 && h.value.hasChecksum);
    auto b = parseZstdBlockHeader(frame[h.value.headerSize .. $]);
    assert(b.ok && b.value.lastBlock && b.value.type == ZstdBlockType.raw
        && b.value.blockSize == 3);
    auto c = parseZstdChecksum(frame[$ - 4 .. $]);
    assert(c.ok && c.value == xxh64Low32(frame[9 .. 12]));
}

@safe unittest
{
    // Round trip for several header shapes.
    foreach (single; [false, true])
        foreach (cs; [0UL, 1, 255, 256, 65791, 65792, 1UL << 31,
                      (1UL << 32) + 5])
            foreach (sum; [false, true])
            {
                ZstdFrameHeader h;
                h.singleSegment = single;
                h.hasContentSize = true;
                h.contentSize = cs;
                h.windowSize = single ? cs : 1UL << 20;
                h.hasChecksum = sum;
                ubyte[16] buf;
                auto w = writeZstdFrameHeader(buf[], h);
                assert(w.ok);
                auto p = parseZstdFrameHeader(buf[0 .. w.value],
                    1UL << 40);
                assert(p.ok);
                assert(p.value.singleSegment == single);
                assert(p.value.hasContentSize);
                assert(p.value.contentSize == cs);
                assert(p.value.hasChecksum == sum);
                assert(p.value.headerSize == w.value);
                if (!single)
                    assert(p.value.windowSize == 1UL << 20);
            }
}

@safe unittest
{
    // Window descriptor covers the requested size.
    foreach (sz; [1024UL, 1025, 4096, 100_000, 1UL << 27])
    {
        auto d = windowDescriptorFor(sz);
        assert(d.ok);
        assert(windowFromDescriptor(d.value) >= sz);
    }
    assert(windowFromDescriptor(0) == 1024);
    assert(windowFromDescriptor(0x08) == 2048);
    assert(windowFromDescriptor(0x01) == 1024 + 128);
}

@safe unittest
{
    // Header rejections.
    immutable ubyte[] badMagic = [0x28, 0xB5, 0x2F, 0xFE, 0x24, 0x05];
    assert(parseZstdFrameHeader(badMagic).error.kind == ErrorKind.corruptInput);

    immutable ubyte[] reserved = [0x28, 0xB5, 0x2F, 0xFD, 0x2C, 0x05];
    assert(parseZstdFrameHeader(reserved).error.kind == ErrorKind.corruptInput);

    immutable ubyte[] trunc = [0x28, 0xB5, 0x2F, 0xFD, 0xE0, 0x05];
    assert(!parseZstdFrameHeader(trunc).ok);

    // Window descriptor 0xF8 -> huge window, over the default cap.
    immutable ubyte[] big = [0x28, 0xB5, 0x2F, 0xFD, 0x00, 0xF8];
    assert(parseZstdFrameHeader(big).error.kind == ErrorKind.unsupported);
    assert(parseZstdFrameHeader(big, ulong.max).ok);
}

@safe unittest
{
    // Block header round trip and rejections.
    foreach (t; [ZstdBlockType.raw, ZstdBlockType.rle, ZstdBlockType.compressed])
        foreach (last; [false, true])
            foreach (sz; [0u, 1, 1000, 131072])
            {
                ubyte[3] buf;
                ZstdBlockHeader b = ZstdBlockHeader(last, t, sz);
                assert(writeZstdBlockHeader(buf[], b).ok);
                auto p = parseZstdBlockHeader(buf[]);
                assert(p.ok);
                assert(p.value.lastBlock == last && p.value.type == t
                    && p.value.blockSize == sz);
            }

    immutable ubyte[] rsv = [0x06, 0x00, 0x00]; // type 3
    assert(!parseZstdBlockHeader(rsv).ok);
    immutable ubyte[] huge = [0x00, 0x00, 0x11]; // size = 0x110000>>3 > 128K
    assert(!parseZstdBlockHeader(huge).ok);
    immutable ubyte[] short2 = [0x01, 0x00];
    assert(!parseZstdBlockHeader(short2).ok);
}

@safe unittest
{
    // Skippable frames and checksum trailer.
    ubyte[32] buf;
    immutable ubyte[] payload = [1, 2, 3, 4, 5];
    auto w = writeZstdSkippableFrame(buf[], payload, 7);
    assert(w.ok && w.value == 13);
    assert(isZstdSkippableMagic(buf[]) && isZstdMagic(buf[]));
    assert(!isZstdFrameMagic(buf[]));
    auto p = parseZstdSkippableFrame(buf[0 .. w.value]);
    assert(p.ok && p.value == 13);
    assert(!parseZstdSkippableFrame(buf[0 .. 10]).ok);

    ubyte[4] c;
    assert(writeZstdChecksum(c[], 0xDEADBEEF).ok);
    assert(c == [0xEF, 0xBE, 0xAD, 0xDE]);
    assert(parseZstdChecksum(c[]).value == 0xDEADBEEF);
    assert(!parseZstdChecksum(c[0 .. 3]).ok);
}
