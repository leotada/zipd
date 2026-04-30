/**
 * `zipd` command dispatch.
 */
module zipd.cli.commands;

import std.file : exists;
import std.format : format;

import zipd.compressor;
import zipd.compressor.unsafe : writeStdoutLine, writeStderrErrorLine,
    readWholeFile, removeFileNoThrow;
import zipd.compressor.scheduler : effectiveThreads;
import zipd.cli.args : Options, Command, helpText;
import zipd.cli.exitcode;

@safe:

int run(Options o) @safe
{
    final switch (o.command)
    {
        case Command.none:       return runHelp(o);
        case Command.compress:   return runCompress(o);
        case Command.decompress: return runDecompress(o);
        case Command.test:       return runTest(o);
        case Command.info:       return runInfo(o);
    }
}

int runHelp(Options) @safe
{
    safePrint(helpText);
    return exitOk;
}

int runCompress(Options o) @safe
{
    if (o.useStdout)
    {
        safeError("--stdout is not implemented yet in Phase 1");
        return exitUnsupported;
    }
    if (exists(o.output) && !o.force)
    {
        safeError("output exists (use --force to overwrite)");
        return exitIo;
    }
    if (o.verbose)
        safeFmt("zipd: compressing %s -> %s (mode=%s, level=%s, threads=%s, chunk=%s)",
            o.input, o.output,
            cast(int) o.settings.mode, o.settings.level,
            effectiveThreads(o.settings.threads), o.settings.chunkSize);

    auto r = compressFile(o.input, o.output, o.settings);
    if (!r.ok)
    {
        safeError(r.error.message);
        return exitCodeFor(r.error.kind);
    }
    if (!o.quiet)
        safeFmt("zipd: %s bytes -> %s bytes (%s blocks)",
            r.value.inputBytes, r.value.outputBytes, r.value.blocks);
    return exitOk;
}

int runDecompress(Options o) @safe
{
    if (o.useStdout)
    {
        safeError("--stdout is not implemented yet in Phase 1");
        return exitUnsupported;
    }
    if (exists(o.output) && !o.force)
    {
        safeError("output exists (use --force to overwrite)");
        return exitIo;
    }
    auto r = decompressFile(o.input, o.output);
    if (!r.ok)
    {
        safeError(r.error.message);
        return exitCodeFor(r.error.kind);
    }
    if (!o.quiet)
        safeFmt("zipd: decompressed %s bytes (%s members)",
            r.value.outputBytes, r.value.blocks);
    return exitOk;
}

int runTest(Options o) @safe
{
    // Decompress to a discarded temporary file. Phase 1 keeps it simple.
    import std.file : tempDir;
    import std.path : buildPath;
    const tmp = buildPath(tempDir(), "zipd-test.tmp");
    auto r = decompressFile(o.input, tmp);
    safeRemove(tmp);
    if (!r.ok)
    {
        safeError(r.error.message);
        return exitCodeFor(r.error.kind);
    }
    if (!o.quiet)
        safeFmt("zipd: %s OK (%s bytes)", o.input, r.value.outputBytes);
    return exitOk;
}

int runInfo(Options o) @safe
{
    ubyte[] bytes;
    try
        bytes = readWholeFile(o.input);
    catch (Exception)
    {
        safeError("cannot read input");
        return exitIo;
    }
    import zipd.compressor.gzip : parseGzipHeader;
    if (bytes.length < 2)
    {
        safeError("file too small");
        return exitCorrupt;
    }
    auto h = parseGzipHeader(bytes);
    if (!h.ok)
    {
        safeError(h.error.message);
        return exitCodeFor(h.error.kind);
    }
    safeFmt("gzip: header=%s bytes flags=0x%02x os=%s",
        h.value.headerSize, h.value.flags, h.value.os);
    return exitOk;
}

// --------------- safe stdio wrappers (delegated to unsafe shim) ---------------

private void safePrint(scope const(char)[] s) @safe
{
    writeStdoutLine(s);
}

private void safeError(scope const(char)[] s) @safe
{
    writeStderrErrorLine(s);
}

private void safeFmt(Args...)(string fmt, Args args) @safe
{
    string s;
    try
        s = format(fmt, args);
    catch (Exception)
        return;
    writeStdoutLine(s);
}

private void safeRemove(scope const(char)[] path) @safe nothrow
{
    removeFileNoThrow(path);
}
