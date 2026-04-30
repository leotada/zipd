/**
 * Argument parser for `zipd`. Hand-written, `@safe`, no external deps.
 */
module zipd.cli.args;

import zipd.compressor.errors : Result, ErrorKind, success, failure;
import zipd.compressor.settings : CompressionSettings, CompressMode;

@safe:

enum Command : ubyte
{
    none,
    compress,
    decompress,
    test,
    info,
}

struct Options
{
    Command             command;
    string              input;
    string              output;
    bool                useStdout;
    bool                force;
    bool                quiet;
    bool                verbose;
    bool                storeName;
    bool                explicitMode;
    CompressionSettings settings;
}

Result!Options parseArgs(scope string[] argv) @safe
{
    Options o;
    if (argv.length < 2)
        return failure!Options(ErrorKind.invalidArgs,
            "missing command (try `zipd compress <input> -o <output>`)");

    switch (argv[1])
    {
        case "compress":   case "c": o.command = Command.compress;   break;
        case "decompress": case "d": o.command = Command.decompress; break;
        case "test":       case "t": o.command = Command.test;       break;
        case "info":                  o.command = Command.info;       break;
        case "-h": case "--help":
            return failure!Options(ErrorKind.invalidArgs, helpText);
        default:
            return failure!Options(ErrorKind.invalidArgs,
                "unknown command");
    }

    for (size_t i = 2; i < argv.length; i++)
    {
        const a = argv[i];
        switch (a)
        {
            case "-o":
                if (++i >= argv.length)
                    return failure!Options(ErrorKind.invalidArgs,
                        "-o requires an argument");
                o.output = argv[i];
                break;
            case "--stdout":
                o.useStdout = true;
                break;
            case "--force":
                o.force = true;
                break;
            case "--quiet":
                o.quiet = true;
                break;
            case "--verbose":
                o.verbose = true;
                break;
            case "--name":
                o.storeName = true;
                break;
            case "--store":
                o.settings.mode = CompressMode.store;
                o.explicitMode = true;
                break;
            case "--level":
                if (++i >= argv.length)
                    return failure!Options(ErrorKind.invalidArgs,
                        "--level requires an argument");
                {
                    auto p = parseUint(argv[i]);
                    if (!p.ok)
                        return failure!Options(p.error.kind, p.error.message);
                    o.settings.level = p.value;
                }
                break;
            case "--threads":
                if (++i >= argv.length)
                    return failure!Options(ErrorKind.invalidArgs,
                        "--threads requires an argument");
                {
                    auto p = parseUint(argv[i]);
                    if (!p.ok)
                        return failure!Options(p.error.kind, p.error.message);
                    o.settings.threads = p.value;
                }
                break;
            case "--chunk-size":
                if (++i >= argv.length)
                    return failure!Options(ErrorKind.invalidArgs,
                        "--chunk-size requires an argument");
                {
                    auto p = parseSize(argv[i]);
                    if (!p.ok)
                        return failure!Options(p.error.kind, p.error.message);
                    o.settings.chunkSize = p.value;
                }
                break;
            default:
                if (a.length > 0 && a[0] == '-')
                    return failure!Options(ErrorKind.invalidArgs,
                        "unknown option");
                if (o.input.length == 0)
                    o.input = a;
                else
                    return failure!Options(ErrorKind.invalidArgs,
                        "unexpected positional argument");
        }
    }

    if (o.useStdout && o.output.length > 0)
        return failure!Options(ErrorKind.invalidArgs,
            "--stdout and -o are mutually exclusive");

    if (o.command == Command.compress || o.command == Command.decompress)
    {
        if (o.input.length == 0)
            return failure!Options(ErrorKind.invalidArgs, "missing <input>");
        if (!o.useStdout && o.output.length == 0)
            return failure!Options(ErrorKind.invalidArgs,
                "missing -o <output> (or pass --stdout)");
    }

    o.settings.storeName = o.storeName;
    return success(o);
}

private Result!uint parseUint(scope string s) pure nothrow @nogc @safe
{
    if (s.length == 0)
        return failure!uint(ErrorKind.invalidArgs, "empty integer");
    uint v = 0;
    foreach (c; s)
    {
        if (c < '0' || c > '9')
            return failure!uint(ErrorKind.invalidArgs, "not an integer");
        const d = cast(uint)(c - '0');
        if (v > (uint.max - d) / 10)
            return failure!uint(ErrorKind.invalidArgs, "integer overflow");
        v = v * 10 + d;
    }
    return success(v);
}

private Result!size_t parseSize(scope string s) pure nothrow @nogc @safe
{
    if (s.length == 0)
        return failure!size_t(ErrorKind.invalidArgs, "empty size");
    size_t mult = 1;
    auto digits = s;
    const last = s[$ - 1];
    if (last == 'k' || last == 'K') { mult = 1024; digits = s[0 .. $ - 1]; }
    else if (last == 'm' || last == 'M') { mult = 1024 * 1024; digits = s[0 .. $ - 1]; }
    else if (last == 'g' || last == 'G') { mult = 1024 * 1024 * 1024; digits = s[0 .. $ - 1]; }
    if (digits.length == 0)
        return failure!size_t(ErrorKind.invalidArgs, "missing size value");
    size_t v = 0;
    foreach (c; digits)
    {
        if (c < '0' || c > '9')
            return failure!size_t(ErrorKind.invalidArgs, "not a size");
        const d = cast(size_t)(c - '0');
        if (v > (size_t.max / 10))
            return failure!size_t(ErrorKind.invalidArgs, "size overflow");
        v = v * 10 + d;
    }
    if (v != 0 && mult > size_t.max / v)
        return failure!size_t(ErrorKind.invalidArgs, "size overflow");
    return success(v * mult);
}

enum string helpText =
"zipd - safe high-level D gzip-compatible compressor

Usage:
  zipd compress   <input> -o <output> [options]
  zipd decompress <input> -o <output> [options]
  zipd test       <input>
  zipd info       <input>

Options:
  --level N         Compression level 1..9 (default 6; ignored in --store mode)
  --threads N       Worker count, 0 = auto (Phase 3)
  --chunk-size SIZE Independent block size, e.g. 256k, 1m, 4m
  --store           Use uncompressed DEFLATE blocks (Phase 1 default)
  --stdout          Write to stdout (mutually exclusive with -o)
  --force           Overwrite output
  --name            Store original filename in gzip FNAME field
  --quiet           Only print errors
  --verbose         Print settings and timing
";

@safe unittest
{
    auto r = parseArgs(["zipd", "compress", "in.txt", "-o", "out.gz"]);
    assert(r.ok);
    assert(r.value.command == Command.compress);
    assert(r.value.input == "in.txt");
    assert(r.value.output == "out.gz");
}

@safe unittest
{
    auto r = parseArgs(["zipd", "compress", "--stdout", "-o", "x", "in"]);
    assert(!r.ok);
    assert(r.error.kind == ErrorKind.invalidArgs);
}

@safe unittest
{
    auto r = parseArgs(["zipd", "compress", "in", "-o", "out", "--chunk-size", "4m"]);
    assert(r.ok);
    assert(r.value.settings.chunkSize == 4 * 1024 * 1024);
}

@safe unittest
{
    auto r = parseArgs(["zipd", "decompress", "in.gz", "-o", "out"]);
    assert(r.ok);
    assert(r.value.command == Command.decompress);
}
