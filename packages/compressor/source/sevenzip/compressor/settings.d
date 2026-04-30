/**
 * Public compressor settings and codec/container enums.
 */
module sevenzip.compressor.settings;

@safe:

/// Compression algorithm selector. Only `deflate` is implemented in v1.
enum CodecId : ubyte
{
    /// DEFLATE (RFC 1951). Phase 1 supports `store` only (BTYPE=00).
    deflate = 1,
    /// Reserved for the optional Phase 5 codec.
    lzma2   = 2,
}

/// Output framing for a compressed stream.
enum ContainerKind : ubyte
{
    /// gzip (RFC 1952). Default and only container in v1.
    gzip       = 1,
    /// Raw DEFLATE bitstream, no framing. Reserved.
    rawDeflate = 2,
    /// zlib (RFC 1950). Reserved.
    zlib       = 3,
}

/// Compression mode. Phase 1 ships only `store`; Phase 2 adds the real
/// DEFLATE engine.
enum CompressMode : ubyte
{
    /// Emit BTYPE=00 (uncompressed) DEFLATE blocks. Always available.
    store   = 0,
    /// Real DEFLATE compression at the configured level. Phase 2.
    deflate = 1,
}

/// Library-wide compression settings.
///
/// All fields have sane defaults suitable for the CLI; the CLI overrides
/// only the fields the user passes on the command line.
struct CompressionSettings
{
    CodecId       codec       = CodecId.deflate;
    ContainerKind container   = ContainerKind.gzip;
    CompressMode  mode        = CompressMode.deflate; // Phase 2 default
    /// gzip-style level, 1..9. Ignored when `mode == store`.
    uint          level       = 6;
    /// 0 means "auto" (logical CPU count). Phase 3 wires this in.
    uint          threads     = 0;
    /// Independent block size for multicore mode. Phase 3 honors this.
    size_t        chunkSize   = 1 * 1024 * 1024;
    /// When true, the gzip FNAME field carries the original file name.
    bool          storeName   = false;
}

/// Statistics returned to the CLI after a successful operation.
struct CompressionStats
{
    ulong  inputBytes;
    ulong  outputBytes;
    ulong  blocks;
    double elapsedSeconds;
}

/// Normalize and validate `s`. Returns the normalized settings or an
/// error if a value is out of range.
import sevenzip.compressor.errors : Result, ErrorKind, success, failure;

Result!CompressionSettings normalize(CompressionSettings s) pure nothrow @nogc @safe
{
    if (s.level < 1 || s.level > 9)
        return failure!CompressionSettings(ErrorKind.invalidArgs,
            "level must be in 1..9");
    if (s.chunkSize == 0)
        return failure!CompressionSettings(ErrorKind.invalidArgs,
            "chunk-size must be > 0");
    // gzip stored-block payloads are <= 65535 bytes, but our chunkSize
    // governs the worker block size, not the deflate sub-block size.
    return success(s);
}

@safe unittest
{
    auto ok = normalize(CompressionSettings.init);
    assert(ok.ok);

    CompressionSettings bad;
    bad.level = 0;
    assert(!normalize(bad).ok);

    bad = CompressionSettings.init;
    bad.chunkSize = 0;
    assert(!normalize(bad).ok);
}
