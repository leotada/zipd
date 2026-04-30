/**
 * CLI exit codes for `dgz`. Mirrors `ErrorKind` numerically.
 */
module sevenzip.cli.exitcode;

import sevenzip.compressor.errors : ErrorKind;

@safe:

enum int exitOk           = 0;
enum int exitGeneric      = 1;
enum int exitInvalidArgs  = 2;
enum int exitIo           = 3;
enum int exitUnsupported  = 4;
enum int exitCorrupt      = 5;
enum int exitChecksum     = 6;
enum int exitInternal     = 8;

int exitCodeFor(ErrorKind k) pure nothrow @nogc
{
    final switch (k)
    {
        case ErrorKind.none:         return exitOk;
        case ErrorKind.generic:      return exitGeneric;
        case ErrorKind.invalidArgs:  return exitInvalidArgs;
        case ErrorKind.io:           return exitIo;
        case ErrorKind.unsupported:  return exitUnsupported;
        case ErrorKind.corruptInput: return exitCorrupt;
        case ErrorKind.checksum:     return exitChecksum;
        case ErrorKind.internal:     return exitInternal;
    }
}
