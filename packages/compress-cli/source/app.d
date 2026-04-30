/**
 * `dgz` entry point.
 */
module app;

import sevenzip.compressor.unsafe : writeStderrErrorLine;
import sevenzip.cli.args : parseArgs;
import sevenzip.cli.commands : run;
import sevenzip.cli.exitcode : exitInvalidArgs, exitCodeFor;

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
