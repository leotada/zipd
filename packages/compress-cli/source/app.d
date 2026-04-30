/**
 * `zipd` entry point.
 */
module app;

import zipd.compressor.unsafe : writeStderrErrorLine;
import zipd.cli.args : parseArgs;
import zipd.cli.commands : run;
import zipd.cli.exitcode : exitInvalidArgs, exitCodeFor;

int main(string[] argv) @safe
{
    auto parsed = parseArgs(argv);
    if (!parsed.ok)
    {
        writeStderrErrorLine(parsed.error.message);
        return exitCodeFor(parsed.error.kind);
    }
    
    auto result = run(parsed.value);

    if (parsed.value.debugMode)
    {
        () @trusted {
            import core.memory : GC;
            import std.stdio : stderr;
            try
            {
                auto ps = GC.profileStats();
                auto s = GC.stats();
                stderr.writefln("[DEBUG] GC usage: %d bytes used in heap, %d bytes free", s.usedSize, s.freeSize);
                stderr.writefln("[DEBUG] GC profile: %d collections, max pause: %s, total pause: %s", ps.numCollections, ps.maxPauseTime, ps.totalPauseTime);
            }
            catch (Exception) {}
        }();
    }

    return result;
}
