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
    return run(parsed.value);
}
