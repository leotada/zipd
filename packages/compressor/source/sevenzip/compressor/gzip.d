/**
 * gzip framing per RFC 1952.
 *
 * Encodes a fixed, deterministic header (no MTIME, no FNAME unless
 * requested) and an 8-byte trailer (CRC32, ISIZE).
 */
module sevenzip.compressor.gzip;

import sevenzip.compressor.errors : Result, ErrorKind, ErrorInfo,
    success, failure, noError;

@safe:

/// Magic bytes for a gzip member: 0x1f 0x8b.
enum ubyte gzipId1 = 0x1F;
enum ubyte gzipId2 = 0x8B;
/// Compression method: deflate.
enum ubyte gzipCmDeflate = 0x08;

/// FLG bits.
enum ubyte gzipFlagText    = 0x01;
enum ubyte gzipFlagHcrc    = 0x02;
enum ubyte gzipFlagExtra   = 0x04;
enum ubyte gzipFlagName    = 0x08;
enum ubyte gzipFlagComment = 0x10;

/// Operating system code stored in the header. We pin this to 255
/// ("unknown") for deterministic output.
enum ubyte gzipOsUnknown = 0xFF;

/// XFL byte. We use 0 ("default") regardless of level for determinism.
enum ubyte gzipXflDefault = 0x00;

/// Header builder. Returns the number of bytes written into `out`.
///
/// `originalName` is optional (slice empty = no FNAME field). When
/// non-empty, it is written as a NUL-terminated ISO-8859-1 string
/// per RFC 1952 §2.3.1.10. Embedded NULs in `originalName` are
/// rejected.
Result!size_t writeGzipHeader(scope ubyte[] dst,
                              scope const(char)[] originalName) pure nothrow @nogc @safe
{
    ubyte flags = 0;
    size_t needed = 10;
    if (originalName.length > 0)
    {
        flags |= gzipFlagName;
        needed += originalName.length + 1; // + trailing NUL
    }
    if (dst.length < needed)
        return failure!size_t(ErrorKind.internal,
            "gzip header destination too small");

    foreach (c; originalName)
        if (c == '\0')
            return failure!size_t(ErrorKind.invalidArgs,
                "embedded NUL in stored filename");

    dst[0] = gzipId1;
    dst[1] = gzipId2;
    dst[2] = gzipCmDeflate;
    dst[3] = flags;
    dst[4] = 0;
    dst[5] = 0;
    dst[6] = 0;
    dst[7] = 0;             // MTIME = 0 (deterministic)
    dst[8] = gzipXflDefault;
    dst[9] = gzipOsUnknown;

    size_t pos = 10;
    if (originalName.length > 0)
    {
        foreach (c; originalName)
            dst[pos++] = cast(ubyte) c;
        dst[pos++] = 0;
    }
    return success(pos);
}

/// Trailer (CRC32, ISIZE), little-endian.
Result!size_t writeGzipTrailer(scope ubyte[] dst,
                               uint crc32Value,
                               uint isizeMod32) pure nothrow @nogc @safe
{
    if (dst.length < 8)
        return failure!size_t(ErrorKind.internal,
            "gzip trailer destination too small");
    dst[0] = cast(ubyte)(crc32Value & 0xFF);
    dst[1] = cast(ubyte)((crc32Value >> 8) & 0xFF);
    dst[2] = cast(ubyte)((crc32Value >> 16) & 0xFF);
    dst[3] = cast(ubyte)((crc32Value >> 24) & 0xFF);
    dst[4] = cast(ubyte)(isizeMod32 & 0xFF);
    dst[5] = cast(ubyte)((isizeMod32 >> 8) & 0xFF);
    dst[6] = cast(ubyte)((isizeMod32 >> 16) & 0xFF);
    dst[7] = cast(ubyte)((isizeMod32 >> 24) & 0xFF);
    return success(cast(size_t) 8);
}

/// Parsed gzip header metadata. Filled by `parseGzipHeader`.
struct GzipHeader
{
    ubyte  flags;
    ubyte  xfl;
    ubyte  os;
    /// Bytes consumed from the input by the header.
    size_t headerSize;
    /// Slice into the input (aliasing) holding the FNAME field's bytes
    /// without the trailing NUL. Empty when FNAME is absent.
    const(ubyte)[] name;
}

/// Parse a gzip header starting at `src[0]`. On success, fills `out`
/// and returns the number of bytes consumed.
Result!GzipHeader parseGzipHeader(return scope const(ubyte)[] src) pure nothrow @nogc @safe
{
    if (src.length < 10)
        return failure!GzipHeader(ErrorKind.corruptInput,
            "gzip header truncated");
    if (src[0] != gzipId1 || src[1] != gzipId2)
        return failure!GzipHeader(ErrorKind.corruptInput,
            "not a gzip stream (bad magic)");
    if (src[2] != gzipCmDeflate)
        return failure!GzipHeader(ErrorKind.unsupported,
            "unsupported gzip compression method");

    GzipHeader h;
    h.flags = src[3];
    h.xfl = src[8];
    h.os = src[9];
    size_t pos = 10;

    // FEXTRA
    if (h.flags & gzipFlagExtra)
    {
        if (pos + 2 > src.length)
            return failure!GzipHeader(ErrorKind.corruptInput,
                "gzip header truncated in FEXTRA length");
        const xlen = cast(size_t)(src[pos] | (cast(uint) src[pos + 1] << 8));
        pos += 2;
        if (pos + xlen > src.length)
            return failure!GzipHeader(ErrorKind.corruptInput,
                "gzip header truncated in FEXTRA payload");
        pos += xlen;
    }

    // FNAME (NUL-terminated)
    if (h.flags & gzipFlagName)
    {
        const start = pos;
        while (pos < src.length && src[pos] != 0)
            pos++;
        if (pos >= src.length)
            return failure!GzipHeader(ErrorKind.corruptInput,
                "gzip header truncated in FNAME");
        h.name = src[start .. pos];
        pos++; // consume NUL
    }

    // FCOMMENT
    if (h.flags & gzipFlagComment)
    {
        while (pos < src.length && src[pos] != 0)
            pos++;
        if (pos >= src.length)
            return failure!GzipHeader(ErrorKind.corruptInput,
                "gzip header truncated in FCOMMENT");
        pos++;
    }

    // FHCRC
    if (h.flags & gzipFlagHcrc)
    {
        if (pos + 2 > src.length)
            return failure!GzipHeader(ErrorKind.corruptInput,
                "gzip header truncated in FHCRC");
        // We do not validate the header CRC in v1 (it is rarely set).
        pos += 2;
    }

    h.headerSize = pos;
    return success(h);
}

/// Parsed trailer.
struct GzipTrailer
{
    uint crc32Value;
    uint isizeMod32;
}

Result!GzipTrailer parseGzipTrailer(scope const(ubyte)[] src) pure nothrow @nogc @safe
{
    if (src.length < 8)
        return failure!GzipTrailer(ErrorKind.corruptInput,
            "gzip trailer truncated");
    GzipTrailer t;
    t.crc32Value = cast(uint) src[0]
        | (cast(uint) src[1] << 8)
        | (cast(uint) src[2] << 16)
        | (cast(uint) src[3] << 24);
    t.isizeMod32 = cast(uint) src[4]
        | (cast(uint) src[5] << 8)
        | (cast(uint) src[6] << 16)
        | (cast(uint) src[7] << 24);
    return success(t);
}

@safe unittest
{
    ubyte[16] hdr;
    auto r = writeGzipHeader(hdr[], "");
    assert(r.ok);
    assert(r.value == 10);
    assert(hdr[0] == 0x1F && hdr[1] == 0x8B && hdr[2] == 0x08);
    assert(hdr[3] == 0); // no flags
    assert(hdr[4 .. 8] == [cast(ubyte) 0, 0, 0, 0]); // MTIME=0
    assert(hdr[9] == 0xFF); // OS unknown
}

@safe unittest
{
    ubyte[32] hdr;
    auto r = writeGzipHeader(hdr[], "hello.txt");
    assert(r.ok);
    assert(r.value == 10 + 9 + 1);
    assert(hdr[3] == gzipFlagName);
    assert(hdr[10 .. 19] == cast(const(ubyte)[]) "hello.txt");
    assert(hdr[19] == 0);
}

@safe unittest
{
    ubyte[8] tr;
    auto r = writeGzipTrailer(tr[], 0xCBF43926, 9);
    assert(r.ok);
    assert(tr == [
        cast(ubyte) 0x26, 0x39, 0xF4, 0xCB,
        9,    0,    0,    0
    ]);
}

@safe unittest
{
    // Round-trip header parse.
    ubyte[64] hdr;
    auto w = writeGzipHeader(hdr[], "x");
    assert(w.ok);
    auto p = parseGzipHeader(hdr[0 .. w.value]);
    assert(p.ok);
    assert(p.value.headerSize == w.value);
    assert(p.value.name == cast(const(ubyte)[]) "x");
}

@safe unittest
{
    ubyte[8] tr;
    auto w = writeGzipTrailer(tr[], 0xDEADBEEF, 42);
    assert(w.ok);
    auto p = parseGzipTrailer(tr[]);
    assert(p.ok);
    assert(p.value.crc32Value == 0xDEADBEEF);
    assert(p.value.isizeMod32 == 42);
}

@safe unittest
{
    // Bad magic is rejected as corrupt input.
    ubyte[10] junk = [cast(ubyte) 'P', 'K', 3, 4, 0, 0, 0, 0, 0, 0];
    auto p = parseGzipHeader(junk[]);
    assert(!p.ok);
    assert(p.error.kind == ErrorKind.corruptInput);
}
