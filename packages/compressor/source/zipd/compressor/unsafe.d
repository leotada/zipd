/**
 * Audited unsafe shim.
 *
 * This is the **only** module in the new compressor packages allowed to
 * use `@trusted`. Each wrapper here exists because the underlying
 * Phobos / druntime API is currently `@system` or template-inferred to
 * `@system` in our usage.
 *
 * Rules for additions:
 *   1. The wrapper must be a thin pass-through. No business logic.
 *   2. Each wrapper must carry a comment explaining the safety
 *      argument: why the caller-visible behavior is memory-safe.
 *   3. No pointer arithmetic. No `cast`s that strip `const`/`shared`.
 *      No GC tricks. No reinterpretation of bytes.
 *   4. If a future Phobos / druntime release makes the wrapped API
 *      genuinely `@safe`, delete the wrapper.
 */
module zipd.compressor.unsafe;

import std.stdio : File;

@safe:

/**
 * Read up to `dst.length` bytes from `f` into `dst`.
 *
 * Returns the slice of `dst` that was actually filled.
 *
 * Safety: `File.rawRead` writes only into the provided buffer and
 * returns a slice of that same buffer. We pass an owned `ubyte[]`
 * slice in and return a slice strictly inside it. No pointer escape,
 * no aliasing of foreign memory.
 */
ubyte[] readInto(ref File f, return scope ubyte[] dst) @trusted
{
    return f.rawRead(dst);
}

/**
 * Write `data` to `f`.
 *
 * Safety: `File.rawWrite` only reads the bytes inside `data`. We do
 * not retain any reference to `data` past the call. No memory escapes
 * into the file handle.
 */
void writeAll(ref File f, scope const(ubyte)[] data) @trusted
{
    f.rawWrite(data);
}

/**
 * Flush `f` to the OS.
 *
 * Safety: `File.flush` performs a syscall on the underlying handle and
 * does not touch caller memory.
 */
void flush(ref File f) @trusted
{
    f.flush();
}

/**
 * Atomically rename `from` to `to`.
 *
 * Safety: `std.file.rename` performs a single rename(2) syscall on
 * two strings; it does not retain or alias them after returning.
 */
void renameFile(scope const(char)[] from, scope const(char)[] to) @trusted
{
    import std.file : rename;
    rename(from, to);
}

/**
 * Best-effort delete of `path`. Errors are swallowed.
 *
 * Safety: `std.file.remove` is a syscall on a string; nothing escapes.
 * We catch `Exception` because a missing file is not an error in the
 * call sites that use this (cleanup of a partial output).
 */
void removeFileNoThrow(scope const(char)[] path) @trusted nothrow
{
    import std.file : remove;
    try
        remove(path);
    catch (Exception)
    {
    }
}

/**
 * Return the size of `f` in bytes, or 0 if the size cannot be
 * determined (e.g., pipes).
 *
 * Safety: `File.size` queries the OS; no caller memory is touched.
 * The cast from `ulong` to `ulong` is identity.
 */
ulong fileSize(ref File f) @trusted nothrow
{
    try
        return f.size;
    catch (Exception)
        return 0;
}

/**
 * Read the entire contents of `path` into a freshly allocated buffer.
 *
 * Safety: `std.file.read` returns a freshly GC-allocated `void[]`
 * owned by the caller; the cast to `ubyte[]` is a header reinterpretation
 * of the same allocation. No aliasing of caller memory.
 */
ubyte[] readWholeFile(string path) @trusted
{
    import std.file : read;
    return cast(ubyte[]) read(path);
}

/**
 * Write `line` followed by '\n' to standard output. Errors are
 * swallowed (a CLI cannot do anything meaningful if stdout is broken).
 *
 * Safety: `stdout.writeln` only reads from `line`; we do not retain it.
 */
void writeStdoutLine(scope const(char)[] line) @trusted nothrow
{
    import std.stdio : stdout;
    try
    {
        stdout.writeln(line);
    }
    catch (Exception)
    {
    }
}

/**
 * Write `"zipd: error: " ~ line ~ '\n'` to standard error.
 *
 * Safety: `stderr.writeln` only reads from `line`; we do not retain it.
 */
void writeStderrErrorLine(scope const(char)[] line) @trusted nothrow
{
    import std.stdio : stderr;
    try
    {
        stderr.writeln("zipd: error: ", line);
    }
    catch (Exception)
    {
    }
}

// ------------------------------------------------------------------ //
// Threading shim. Used only by `zipd.compressor.scheduler`.
// Each wrapper exists because `core.thread` / `core.sync` are
// `@system`. The scheduler observes the discipline that:
//   1. shared mutable state is only touched while the matching
//      mutex is held;
//   2. delegates passed to `spawnThread` outlive the spawned thread
//      (joined via `joinThread` before the captured state is freed).

import core.thread : Thread;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;

/// Logical CPU count, or 1 if it cannot be determined.
///
/// Safety: `std.parallelism.totalCPUs` reads a process-global integer
/// initialized at module ctor time. No caller memory is touched.
size_t cpuCount() @trusted nothrow
{
    try
    {
        import std.parallelism : totalCPUs;
        const n = totalCPUs;
        return n < 1 ? 1 : cast(size_t) n;
    }
    catch (Exception)
        return 1;
}

/// Allocate a new mutex.
///
/// Safety: returns a fresh GC-allocated `Mutex` instance; no aliasing
/// of caller memory.
Mutex newMutex() @trusted
{
    return new Mutex;
}

/// Allocate a new condition variable bound to `m`.
///
/// Safety: returns a fresh GC-allocated `Condition` referencing the
/// caller-provided `Mutex`. The mutex is retained for the lifetime of
/// the condition; this is a normal D reference, not pointer arithmetic.
Condition newCondition(Mutex m) @trusted
{
    return new Condition(m);
}

/// Lock `m`.
///
/// Safety: `Mutex.lock_nothrow` is a syscall on the underlying OS
/// primitive; no caller memory is touched.
void mutexLock(Mutex m) @trusted nothrow
{
    m.lock_nothrow();
}

/// Unlock `m`.
///
/// Safety: same as `mutexLock`.
void mutexUnlock(Mutex m) @trusted nothrow
{
    m.unlock_nothrow();
}

/// Wait on `c`. Caller must hold the bound mutex.
///
/// Safety: `Condition.wait` releases and re-acquires the bound mutex
/// around an OS wait. No caller memory is touched.
void condWait(Condition c) @trusted nothrow
{
    try
        c.wait();
    catch (Exception)
    {
        // Spurious failure to wait degrades into a busy-spin in the
        // caller's loop, which still makes forward progress because
        // the predicate is rechecked.
    }
}

/// Wake one waiter on `c`. Caller must hold the bound mutex.
///
/// Safety: same as `condWait`.
void condNotifyOne(Condition c) @trusted nothrow
{
    try
        c.notify();
    catch (Exception)
    {
    }
}

/// Wake all waiters on `c`. Caller must hold the bound mutex.
///
/// Safety: same as `condWait`.
void condNotifyAll(Condition c) @trusted nothrow
{
    try
        c.notifyAll();
    catch (Exception)
    {
    }
}

/// Spawn a thread that runs `dg`. Returns the started `Thread`.
///
/// Safety: the delegate body is `@safe nothrow`; we cast away the
/// safety attributes only to satisfy `core.thread.Thread`'s
/// `@system` constructor signature. The body itself remains `@safe`.
/// The caller is responsible for joining the thread before the state
/// captured by `dg` is freed.
Thread spawnThread(void delegate() @safe nothrow dg) @trusted
{
    void delegate() raw = cast(void delegate()) dg;
    auto t = new Thread(raw);
    t.isDaemon = false;
    t.start();
    return t;
}

/// Join a previously-spawned thread.
///
/// Safety: `Thread.join` blocks the caller until the target thread
/// terminates. No caller memory is touched.
void joinThread(Thread t) @trusted
{
    t.join();
}
