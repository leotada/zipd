/**
 * High-level file API: `compressFile` / `decompressFile`.
 *
 * Phase 1 supports the gzip container with the `store` DEFLATE mode.
 * Phase 2 will swap in the real DEFLATE encoder; this module's API is
 * stable across that transition.
 *
 * The implementation is `@safe` end-to-end except for the audited
 * `unsafe.d` shim used for `File` I/O and atomic rename.
 */
module sevenzip.compressor.streaming;

import std.stdio : File;

import sevenzip.compressor.errors : Result, ErrorKind, ErrorInfo,
    success, failure, noError;
import sevenzip.compressor.settings : CompressionSettings, CompressionStats,
    ContainerKind, CompressMode, normalize;
import sevenzip.compressor.checksum : Crc32;
import sevenzip.compressor.deflate_enc : storeEncode, storeEncodeBound;
import sevenzip.compressor.deflate_enc_huffman :
    deflateEncode, deflateEncodeBound;
import sevenzip.compressor.deflate_dec : deflateDecode;
import sevenzip.compressor.gzip : writeGzipHeader, writeGzipTrailer,
    parseGzipHeader, parseGzipTrailer;
import sevenzip.compressor.scheduler : compressMultiMember, effectiveThreads;
import sevenzip.compressor.unsafe : readInto, writeAll, flush,
    renameFile, removeFileNoThrow;

@safe:

/// I/O block size. Independent of the compressor's chunkSize.
private enum size_t ioBlockBytes = 64 * 1024;

/**
 * Compress `inputPath` to `outputPath` according to `settings`.
 *
 * Output is written atomically: data goes to `outputPath ~ ".tmp"`,
 * which is renamed onto `outputPath` only on success. On failure the
 * temporary file is removed.
 *
 * Phase 1 always emits a single gzip member whose DEFLATE payload is
 * a sequence of stored (BTYPE=00) blocks. The CLI's `--store` mode
 * is the default in Phase 1.
 */
Result!CompressionStats compressFile(string inputPath,
                                     string outputPath,
                                     CompressionSettings settings) @safe
{
    auto norm = normalize(settings);
    if (!norm.ok)
        return failure!CompressionStats(norm.error.kind, norm.error.message);
    settings = norm.value;

    if (settings.container != ContainerKind.gzip)
        return failure!CompressionStats(ErrorKind.unsupported,
            "only gzip container is supported in v1");
    if (settings.mode != CompressMode.store
        && settings.mode != CompressMode.deflate)
        return failure!CompressionStats(ErrorKind.unsupported,
            "unknown compression mode");

    string tmpPath = outputPath ~ ".tmp";

    File inFile, outFile;
    try
    {
        inFile = File(inputPath, "rb");
    }
    catch (Exception e)
    {
        return failure!CompressionStats(ErrorKind.io,
            "cannot open input file");
    }
    try
    {
        outFile = File(tmpPath, "wb");
    }
    catch (Exception e)
    {
        return failure!CompressionStats(ErrorKind.io,
            "cannot open output file");
    }

    scope (failure) removeFileNoThrow(tmpPath);

    // Phase 3: multi-threaded path. When the user asks for >1 worker
    // (or auto-detects to >1 on this host), emit a stream of
    // independent gzip members. Skip when --name is set, because the
    // multi-member writer cannot stamp FNAME on the very first member
    // without a re-encode pass.
    const wantThreads = effectiveThreads(settings.threads);
    if (wantThreads > 1 && !settings.storeName)
    {
        auto rmt = compressMultiMember(inFile, outFile, settings, "");
        if (!rmt.ok)
            return failure!CompressionStats(rmt.error.kind, rmt.error.message);
        try
            flush(outFile);
        catch (Exception)
            return failure!CompressionStats(ErrorKind.io, "flush failed");
        outFile = File.init;
        try
            renameFile(tmpPath, outputPath);
        catch (Exception)
            return failure!CompressionStats(ErrorKind.io, "rename failed");
        return success(rmt.value);
    }

    // gzip header (no FNAME for determinism unless storeName is true).
    ubyte[512] hdrBuf;
    auto hdrLen = writeGzipHeader(hdrBuf[],
        settings.storeName ? inputPath : "");
    if (!hdrLen.ok)
        return failure!CompressionStats(hdrLen.error.kind, hdrLen.error.message);

    auto writeRes = safeWrite(outFile, hdrBuf[0 .. hdrLen.value]);
    if (!writeRes.ok)
        return failure!CompressionStats(writeRes.kind, writeRes.message);

    Crc32 crc;
    ulong inputBytes = 0;
    ulong outputBytes = hdrLen.value;
    ulong blocks = 0;

    if (settings.mode == CompressMode.deflate)
    {
        // Phase 2: read whole input, encode in one fixed-Huffman pass.
        auto allInput = readAllBytes(inFile);
        if (!allInput.ok)
            return failure!CompressionStats(allInput.error.kind, allInput.error.message);
        const(ubyte)[] data = allInput.value;
        crc.put(data);
        inputBytes = data.length;

        auto encBuf = new ubyte[deflateEncodeBound(data.length)];
        auto enc = deflateEncode(data, encBuf, settings.level);
        if (!enc.ok)
            return failure!CompressionStats(enc.error.kind, enc.error.message);
        auto wr0 = safeWrite(outFile, encBuf[0 .. enc.value]);
        if (!wr0.ok)
            return failure!CompressionStats(wr0.kind, wr0.message);
        outputBytes += enc.value;
        blocks = 1;
    }
    else
    {
        auto inputBuf = new ubyte[ioBlockBytes];
        // Worst case for store-encoded I/O block.
        auto encBuf = new ubyte[storeEncodeBound(ioBlockBytes) + 16];

        while (true)
        {
            ubyte[] got;
            try
                got = readInto(inFile, inputBuf);
            catch (Exception)
                return failure!CompressionStats(ErrorKind.io, "read failed");

            if (got.length == 0)
                break;

            crc.put(got);
            inputBytes += got.length;

            // Encode this I/O block as DEFLATE stored blocks. We emit
            // one bitstream per I/O block, all marked non-final; the
            // final BFINAL=1 block is emitted after the loop with an
            // empty payload.
            auto enc = storeEncodeNonFinal(got, encBuf);
            if (!enc.ok)
                return failure!CompressionStats(enc.error.kind, enc.error.message);

            auto wr = safeWrite(outFile, encBuf[0 .. enc.value]);
            if (!wr.ok)
                return failure!CompressionStats(wr.kind, wr.message);

            outputBytes += enc.value;
            blocks++;
        }

        // Final empty BFINAL=1 stored block to terminate the stream.
        immutable ubyte[5] finalBlock = [0x01, 0x00, 0x00, 0xFF, 0xFF];
        auto wr = safeWrite(outFile, finalBlock[]);
        if (!wr.ok)
            return failure!CompressionStats(wr.kind, wr.message);
        outputBytes += finalBlock.length;
        blocks++;
    }

    // Trailer.
    ubyte[8] tr;
    auto trRes = writeGzipTrailer(tr[], crc.finish(),
        cast(uint)(inputBytes & 0xFFFFFFFFu));
    if (!trRes.ok)
        return failure!CompressionStats(trRes.error.kind, trRes.error.message);
    auto wr2 = safeWrite(outFile, tr[]);
    if (!wr2.ok)
        return failure!CompressionStats(wr2.kind, wr2.message);
    outputBytes += tr.length;

    try
        flush(outFile);
    catch (Exception)
        return failure!CompressionStats(ErrorKind.io, "flush failed");

    // Close before rename so Windows is happy (no-op on POSIX).
    outFile = File.init;
    try
        renameFile(tmpPath, outputPath);
    catch (Exception)
        return failure!CompressionStats(ErrorKind.io, "rename failed");

    CompressionStats st;
    st.inputBytes = inputBytes;
    st.outputBytes = outputBytes;
    st.blocks = blocks;
    st.elapsedSeconds = 0;
    return success(st);
}

/**
 * Decompress `inputPath` (a gzip stream, possibly multi-member) to
 * `outputPath`. Validates CRC32 and ISIZE for every member.
 *
 * Phase 1 supports stored DEFLATE blocks only. Encountering a Huffman
 * block returns `ErrorKind.unsupported`.
 */
Result!CompressionStats decompressFile(string inputPath,
                                       string outputPath) @safe
{
    string tmpPath = outputPath ~ ".tmp";

    File inFile, outFile;
    try
        inFile = File(inputPath, "rb");
    catch (Exception)
        return failure!CompressionStats(ErrorKind.io, "cannot open input file");
    try
        outFile = File(tmpPath, "wb");
    catch (Exception)
        return failure!CompressionStats(ErrorKind.io, "cannot open output file");

    scope (failure) removeFileNoThrow(tmpPath);

    // Phase 1: slurp the whole input. Phase 2 replaces this with a
    // streaming bit reader that does not need the input in one slice.
    auto allInput = readAllBytes(inFile);
    if (!allInput.ok)
        return failure!CompressionStats(allInput.error.kind, allInput.error.message);
    const(ubyte)[] src = allInput.value;

    ulong inputBytes = 0;
    ulong outputBytes = 0;
    ulong blocks = 0;

    while (src.length > 0)
    {
        auto hdr = parseGzipHeader(src);
        if (!hdr.ok)
            return failure!CompressionStats(hdr.error.kind, hdr.error.message);
        src = src[hdr.value.headerSize .. $];

        // Decode DEFLATE; we don't know the unpacked size yet, so we
        // grow an output buffer as needed. ioBlockBytes is a sensible
        // initial guess.
        auto decoded = decodeUntilFinal(src);
        if (!decoded.ok)
            return failure!CompressionStats(decoded.error.kind, decoded.error.message);

        const consumed = decoded.value.consumed;
        const data = decoded.value.bytes;
        src = src[consumed .. $];

        if (src.length < 8)
            return failure!CompressionStats(ErrorKind.corruptInput,
                "gzip trailer missing");
        auto tr = parseGzipTrailer(src[0 .. 8]);
        if (!tr.ok)
            return failure!CompressionStats(tr.error.kind, tr.error.message);
        src = src[8 .. $];

        import sevenzip.compressor.checksum : crc32;
        if (crc32(data) != tr.value.crc32Value)
            return failure!CompressionStats(ErrorKind.checksum,
                "CRC32 mismatch");
        if ((cast(uint)(data.length & 0xFFFFFFFFu)) != tr.value.isizeMod32)
            return failure!CompressionStats(ErrorKind.checksum,
                "ISIZE mismatch");

        auto wr = safeWrite(outFile, data);
        if (!wr.ok)
            return failure!CompressionStats(wr.kind, wr.message);

        inputBytes += data.length;
        outputBytes += data.length;
        blocks++;
    }

    try
        flush(outFile);
    catch (Exception)
        return failure!CompressionStats(ErrorKind.io, "flush failed");
    outFile = File.init;
    try
        renameFile(tmpPath, outputPath);
    catch (Exception)
        return failure!CompressionStats(ErrorKind.io, "rename failed");

    CompressionStats st;
    st.inputBytes = inputBytes;
    st.outputBytes = outputBytes;
    st.blocks = blocks;
    return success(st);
}

// ------------------------------------------------------------------
// Internal helpers

/// Encode `input` as a sequence of stored DEFLATE blocks, all marked
/// non-final. Returns the number of bytes written. Mirrors
/// `storeEncode` but with BFINAL=0 for every block.
private Result!size_t storeEncodeNonFinal(scope const(ubyte)[] input,
                                          scope ubyte[] output) pure nothrow @nogc @safe
{
    import sevenzip.compressor.deflate_enc : maxStoredBlockBytes;

    if (input.length == 0)
        return success(cast(size_t) 0);
    const need = input.length
        + ((input.length + maxStoredBlockBytes - 1) / maxStoredBlockBytes) * 5;
    if (output.length < need)
        return failure!size_t(ErrorKind.internal,
            "store encode buffer too small");

    size_t inPos = 0;
    size_t outPos = 0;
    while (inPos < input.length)
    {
        const remaining = input.length - inPos;
        const chunk = remaining > maxStoredBlockBytes
            ? maxStoredBlockBytes : remaining;
        output[outPos++] = 0x00; // BFINAL=0, BTYPE=00
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

private struct DecodedMember
{
    size_t  consumed;
    ubyte[] bytes;
}

private Result!DecodedMember decodeUntilFinal(scope const(ubyte)[] src) @safe
{
    // Output size is unknown until we decode. Start at max(8 KiB, 4*src)
    // and grow geometrically on output-overflow until we succeed or hit
    // the safety cap. The 1 GiB cap matches the per-member soft limit
    // documented in the plan; corrupt streams that try to expand past
    // it are rejected as `corruptInput`.
    enum size_t softCap = 1u << 30;
    size_t cap = src.length * 4 + 8 * 1024;
    while (true)
    {
        if (cap > softCap)
            return failure!DecodedMember(ErrorKind.corruptInput,
                "decoded member would exceed 1 GiB soft cap");
        auto outBuf = new ubyte[cap];
        auto r = deflateDecode(src, outBuf);
        if (r.ok)
        {
            DecodedMember m;
            m.consumed = r.value.consumed;
            m.bytes = outBuf[0 .. r.value.produced];
            return success(m);
        }
        if (r.error.kind != ErrorKind.internal)
            return failure!DecodedMember(r.error.kind, r.error.message);
        // Output buffer was too small; retry with a larger one.
        cap = cap < softCap / 2 ? cap * 2 : softCap;
    }
}

private struct WriteErr
{
    ErrorKind kind;
    string    message;

    bool ok() const pure nothrow @nogc { return kind == ErrorKind.none; }
}

private WriteErr safeWrite(ref File f, scope const(ubyte)[] data) @safe
{
    try
        writeAll(f, data);
    catch (Exception)
        return WriteErr(ErrorKind.io, "write failed");
    return WriteErr(ErrorKind.none, "");
}

private Result!(ubyte[]) readAllBytes(ref File f) @safe
{
    import sevenzip.compressor.unsafe : fileSize;
    const sz = fileSize(f);
    auto buf = new ubyte[sz == 0 ? ioBlockBytes : cast(size_t) sz];
    size_t pos = 0;
    while (true)
    {
        if (pos == buf.length)
            buf.length = buf.length * 2;
        ubyte[] got;
        try
            got = readInto(f, buf[pos .. $]);
        catch (Exception)
            return failure!(ubyte[])(ErrorKind.io, "read failed");
        if (got.length == 0)
            break;
        pos += got.length;
    }
    return success(buf[0 .. pos]);
}

@safe unittest
{
    import std.file : tempDir, write, read, remove, exists;
    import std.path : buildPath;

    const dir = tempDir();
    const inPath = buildPath(dir, "dgz-roundtrip.in");
    const gzPath = buildPath(dir, "dgz-roundtrip.in.gz");
    const outPath = buildPath(dir, "dgz-roundtrip.out");

    immutable ubyte[] payload = cast(immutable(ubyte)[]) "hello, gzip world!";
    write(inPath, payload);

    CompressionSettings s;
    s.mode = CompressMode.store;
    auto c = compressFile(inPath, gzPath, s);
    assert(c.ok);
    assert(c.value.inputBytes == payload.length);

    auto d = decompressFile(gzPath, outPath);
    assert(d.ok);
    auto round = cast(const(ubyte)[]) read(outPath);
    assert(round == payload);

    remove(inPath);
    remove(gzPath);
    remove(outPath);
}

@safe unittest
{
    // Empty input round trip.
    import std.file : tempDir, write, read, remove;
    import std.path : buildPath;

    const dir = tempDir();
    const inPath = buildPath(dir, "dgz-empty.in");
    const gzPath = buildPath(dir, "dgz-empty.in.gz");
    const outPath = buildPath(dir, "dgz-empty.out");

    write(inPath, cast(immutable(ubyte)[]) "");
    auto c = compressFile(inPath, gzPath, CompressionSettings.init);
    assert(c.ok);
    auto d = decompressFile(gzPath, outPath);
    assert(d.ok);
    assert((cast(const(ubyte)[]) read(outPath)).length == 0);

    remove(inPath);
    remove(gzPath);
    remove(outPath);
}
