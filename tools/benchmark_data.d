module benchmark_data;

import std.file : mkdirRecurse;
import std.format : format;
import std.path : buildPath;
import std.stdio : File;
import std.string : representation;

enum compressibleSize = 128UL * 1024 * 1024;
enum mixedSize = 128UL * 1024 * 1024;
enum lcgSize = 64UL * 1024 * 1024;
enum blockBytes = 1 << 20;

void main(string[] args)
{
    const outDir = args.length > 1 ? args[1] : "tools/benchmark-data";
    mkdirRecurse(outDir);

    writePattern(
        buildPath(outDir, "compressible-128m.txt"),
        compressibleSize,
        "the quick brown fox jumps over the lazy dog\n".representation);
    writeMixedLog(buildPath(outDir, "mixed-128m.log"), mixedSize);
    writeLcg(buildPath(outDir, "lcg-64m.bin"), lcgSize);
}

void writePattern(string path, ulong targetBytes, const(ubyte)[] pattern)
{
    auto file = File(path, "wb");
    ubyte[] chunk;
    chunk.reserve(blockBytes);
    while (chunk.length + pattern.length <= blockBytes)
        chunk ~= pattern;
    if (chunk.length == 0)
        chunk ~= pattern;

    ulong remaining = targetBytes;
    while (remaining > 0)
    {
        const amount = remaining < chunk.length ? cast(size_t) remaining : chunk.length;
        file.rawWrite(chunk[0 .. amount]);
        remaining -= amount;
    }
}

void writeMixedLog(string path, ulong targetBytes)
{
    auto file = File(path, "wb");
    immutable levels = ["TRACE", "DEBUG", "INFO", "WARN", "ERROR"];
    immutable services = ["scheduler", "writer", "lz77", "huffman", "cli", "checksum"];
    immutable regions = ["us-east", "us-west", "eu-central", "sa-east"];

    ulong written = 0;
    ulong lineNo = 0;
    while (written < targetBytes)
    {
        const line = format(
            "2026-04-29T12:%02d:%02dZ %s req=%08d svc=%s region=%s ratio=%d.%d chunk=%sk msg=deterministic benchmark record %08d\n",
            cast(uint)(lineNo % 60),
            cast(uint)((lineNo * 7) % 60),
            levels[lineNo % levels.length],
            lineNo,
            services[(lineNo * 3) % services.length],
            regions[(lineNo * 5) % regions.length],
            cast(uint)((lineNo % 97) + 3),
            cast(uint)((lineNo * 11) % 10),
            cast(uint)((1UL << (lineNo % 5)) * 64),
            lineNo);
        const bytes = line.representation;
        const amount = written + bytes.length > targetBytes
            ? cast(size_t)(targetBytes - written)
            : bytes.length;
        file.rawWrite(bytes[0 .. amount]);
        written += amount;
        ++lineNo;
    }
}

void writeLcg(string path, ulong targetBytes)
{
    auto file = File(path, "wb");
    ubyte[] buffer;
    buffer.length = blockBytes;

    uint state = 1;
    ulong remaining = targetBytes;
    while (remaining > 0)
    {
        const amount = remaining < buffer.length ? cast(size_t) remaining : buffer.length;
        foreach (i; 0 .. amount)
        {
            state = cast(uint)((cast(ulong) state * 48_271UL) % 2_147_483_647UL);
            buffer[i] = cast(ubyte)(state & 0xFF);
        }
        file.rawWrite(buffer[0 .. amount]);
        remaining -= amount;
    }
}