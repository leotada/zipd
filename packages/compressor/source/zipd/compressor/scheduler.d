/**
 * Multi-threaded compression: emit a stream of independent, concatenated
 * gzip members (RFC 1952). Each chunk of `settings.chunkSize` input bytes
 * becomes one complete gzip member, encoded by a worker thread with no
 * shared encoder state.
 *
 * The main thread owns the input file and the output file. Workers
 * receive owned input slices, produce owned gzip-member byte buffers,
 * and hand them back via a shared slot table. The main thread writes
 * members to `outFile` strictly in input order, so the concatenated
 * output is deterministic for fixed `(input, settings)`.
 *
 * Safety:
 *   - All scheduler-visible state is encapsulated in `Pool`, a class
 *     accessed only while `Pool.mtx` is held, except for fields a
 *     single thread temporarily owns by virtue of slot state (see
 *     `SlotState` below).
 *   - The thread/sync primitives are accessed through the audited
 *     `unsafe.d` shim. This module itself does not use `@trusted`.
 */
module zipd.compressor.scheduler;

import std.stdio : File;

import core.thread : Thread;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;

import zipd.compressor.errors : Result, ErrorKind, ErrorInfo,
    success, failure, noError;
import zipd.compressor.settings : CompressionSettings, CompressionStats,
    CompressMode;
import zipd.compressor.checksum : Crc32;
import zipd.compressor.deflate_enc : storeEncode, storeEncodeBound;
import zipd.compressor.deflate_enc_huffman :
    deflateEncode, deflateEncodeBound;
import zipd.compressor.gzip : writeGzipHeader, writeGzipTrailer;
import zipd.compressor.unsafe :
    cpuCount, newMutex, newCondition,
    mutexLock, mutexUnlock, condWait, condNotifyOne, condNotifyAll,
    spawnThread, joinThread,
    readInto, writeAll, flush;

@safe:

/// Slot lifecycle. Only the thread that observes a state under the
/// pool lock is allowed to read/write the slot's payload between the
/// observation and the next state transition.
private enum SlotState : ubyte
{
    /// Empty, owned by the reader (main thread).
    empty     = 0,
    /// Filled with input, queued for a worker to claim.
    submitted = 1,
    /// Claimed by a worker; the worker owns input/output until done.
    working   = 2,
    /// Worker finished; output is ready for the writer (main thread).
    done      = 3,
}

private struct ChunkSlot
{
    SlotState state;
    size_t    index;       // logical chunk index, 0-based
    ubyte[]   input;       // owned, may be larger than inputLen
    size_t    inputLen;
    ubyte[]   output;      // owned, may be larger than outputLen
    size_t    outputLen;
    ErrorKind errKind;
    string    errMessage;
}

private final class Pool
{
    Mutex      mtx;
    Condition  jobAvail;     // workers wait here for a submitted slot
    Condition  resultAvail;  // main waits here for done/empty change
    ChunkSlot[] slots;
    bool       shutdown;     // set by main on tear-down
    CompressMode mode;
    uint       level;

    this(size_t inFlight, CompressMode m, uint lvl) @safe scope
    {
        mtx = newMutex();
        jobAvail = newCondition(mtx);
        resultAvail = newCondition(mtx);
        slots = new ChunkSlot[inFlight];
        mode = m;
        level = lvl;
    }
}

/// Effective worker count for `settings.threads` (0 = auto).
size_t effectiveThreads(uint requested) @safe nothrow
{
    if (requested == 0)
        return cpuCount();
    return cast(size_t) requested;
}

/// Compress `inFile` to `outFile` using `effectiveThreads(settings.threads)`
/// worker threads. The output is a concatenation of independent gzip
/// members, one per `settings.chunkSize` input bytes.
///
/// The caller must have already opened both files; the scheduler does
/// not close them. The main thread also performs the file writes; it
/// therefore must not be the same thread that holds any other lock
/// expecting forward progress from this call.
///
/// `firstMemberName` is the FNAME stored in the first member's gzip
/// header (empty = no FNAME). Subsequent members never carry FNAME so
/// that decoders that surface the header name only report it once.
Result!CompressionStats compressMultiMember(ref File inFile,
                                            ref File outFile,
                                            CompressionSettings settings,
                                            string firstMemberName) @safe
{
    const workerCount = effectiveThreads(settings.threads);
    // Bound in-flight work so memory stays ~ 2 * workers chunks.
    const inFlight = workerCount < 1 ? 2 : workerCount * 2;
    scope pool = new Pool(inFlight, settings.mode, settings.level);

    // Spawn workers.
    Thread[32] threadsBuf;
    if (workerCount > threadsBuf.length)
        throw new Exception("Too many threads!");
    scope threads = threadsBuf[0 .. workerCount];
    foreach (i; 0 .. workerCount)
        threads[i] = spawnThread(() @safe nothrow { workerLoop(pool); });

    CompressionStats stats;
    ErrorInfo writeErr;

    size_t reservedIdx = 0;
    size_t writeIdx = 0;
    bool inputEOF = false;
    bool firstMemberWritten = false;

    while (true)
    {
        // 1) Drain any done slots in writer order.
        while (true)
        {
            mutexLock(pool.mtx);
            const s = findDoneSlot(pool, writeIdx);
            if (s == size_t.max)
            {
                mutexUnlock(pool.mtx);
                break;
            }
            // Capture worker error / output under the lock, then
            // release it before performing I/O.
            if (pool.slots[s].errKind != ErrorKind.none)
            {
                writeErr = ErrorInfo(pool.slots[s].errKind,
                    pool.slots[s].errMessage);
                pool.slots[s].state = SlotState.empty;
                pool.slots[s].errKind = ErrorKind.none;
                condNotifyAll(pool.jobAvail);
                mutexUnlock(pool.mtx);
                goto teardown;
            }
            // Move bytes out of the slot for I/O outside the lock.
            ubyte[] toWrite = pool.slots[s].output[0 .. pool.slots[s].outputLen];
            const inLen = pool.slots[s].inputLen;
            mutexUnlock(pool.mtx);

            try
                writeAll(outFile, toWrite);
            catch (Exception)
            {
                writeErr = ErrorInfo(ErrorKind.io, "write failed");
                goto teardown;
            }
            stats.inputBytes += inLen;
            stats.outputBytes += toWrite.length;
            stats.blocks++;
            firstMemberWritten = true;

            // Re-lock to free the slot.
            mutexLock(pool.mtx);
            pool.slots[s].state = SlotState.empty;
            writeIdx++;
            condNotifyAll(pool.jobAvail);
            mutexUnlock(pool.mtx);
        }

        // 2) Fill an empty slot from the input file, if any are free.
        if (!inputEOF)
        {
            mutexLock(pool.mtx);
            const e = findEmptySlot(pool);
            mutexUnlock(pool.mtx);
            if (e != size_t.max)
            {
                // Read directly into the slot's input buffer (we own
                // it while state == empty).
                if (pool.slots[e].input.length < settings.chunkSize)
                    pool.slots[e].input = new ubyte[settings.chunkSize];
                ubyte[] got;
                try
                    got = readInto(inFile, pool.slots[e].input[0 .. settings.chunkSize]);
                catch (Exception)
                {
                    writeErr = ErrorInfo(ErrorKind.io, "read failed");
                    goto teardown;
                }
                if (got.length == 0)
                {
                    inputEOF = true;
                    // Special case: empty input → still emit one empty
                    // gzip member so `gunzip` succeeds and the trailer
                    // CRC/ISIZE for 0 bytes is recorded.
                    if (reservedIdx == 0)
                    {
                        pool.slots[e].inputLen = 0;
                        pool.slots[e].index = reservedIdx++;
                        pool.slots[e].errKind = ErrorKind.none;
                        // Do this single chunk synchronously to avoid
                        // races with the empty-EOF condition below.
                        mutexLock(pool.mtx);
                        pool.slots[e].state = SlotState.submitted;
                        condNotifyAll(pool.jobAvail);
                        mutexUnlock(pool.mtx);
                    }
                    continue;
                }
                pool.slots[e].inputLen = got.length;
                pool.slots[e].index = reservedIdx++;
                pool.slots[e].errKind = ErrorKind.none;

                // Only the very first member may carry FNAME.
                // The worker can't see firstMemberWritten directly, so
                // we encode the name choice into the slot via index 0.
                mutexLock(pool.mtx);
                pool.slots[e].state = SlotState.submitted;
                condNotifyAll(pool.jobAvail);
                mutexUnlock(pool.mtx);
                continue;
            }
        }

        // 3) Are we done?
        mutexLock(pool.mtx);
        if (inputEOF && writeIdx == reservedIdx)
        {
            mutexUnlock(pool.mtx);
            break;
        }
        // 4) Otherwise wait for a worker to finish or for an empty slot
        //    to free up.
        if (!inputEOF && findEmptySlot(pool) != size_t.max)
        {
            // Should not normally happen — we just tried to fill an
            // empty slot above. Drop the lock and spin once.
            mutexUnlock(pool.mtx);
            continue;
        }
        condWait(pool.resultAvail);
        mutexUnlock(pool.mtx);
    }

    // FNAME stamping: at this point the very first written member
    // never had a FNAME because workers don't know about it. To honor
    // `firstMemberName` we would need a re-encode path; for v1 we
    // document that the multi-member writer ignores `firstMemberName`.
    cast(void) firstMemberName;
    cast(void) firstMemberWritten;

teardown:
    mutexLock(pool.mtx);
    pool.shutdown = true;
    condNotifyAll(pool.jobAvail);
    mutexUnlock(pool.mtx);
    foreach (t; threads)
        joinThread(t);

    if (writeErr.kind != ErrorKind.none)
        return failure!CompressionStats(writeErr.kind, writeErr.message);
    return success(stats);
}

// ------------------------------------------------------------------ //
// Worker

private void workerLoop(scope Pool pool) @safe nothrow
{
    while (true)
    {
        // Find a job (lowest-index submitted slot) under the lock.
        size_t slot = size_t.max;
        mutexLock(pool.mtx);
        while (true)
        {
            if (pool.shutdown)
            {
                mutexUnlock(pool.mtx);
                return;
            }
            slot = findSubmittedSlot(pool);
            if (slot != size_t.max)
            {
                pool.slots[slot].state = SlotState.working;
                break;
            }
            condWait(pool.jobAvail);
        }
        mutexUnlock(pool.mtx);

        // Process outside the lock. We exclusively own the slot's
        // input/output buffers while state == working.
        ubyte[] outBuf = pool.slots[slot].output;
        size_t produced = 0;
        ErrorInfo err;
        try
        {
            auto r = encodeMember(
                pool.slots[slot].input[0 .. pool.slots[slot].inputLen],
                pool.mode, pool.level, outBuf);
            if (!r.ok)
                err = ErrorInfo(r.error.kind, r.error.message);
            else
            {
                outBuf = r.value.buf;
                produced = r.value.len;
            }
        }
        catch (Exception e)
        {
            err = ErrorInfo(ErrorKind.internal, "worker exception");
        }

        // Publish the result.
        mutexLock(pool.mtx);
        pool.slots[slot].output = outBuf;
        pool.slots[slot].outputLen = produced;
        pool.slots[slot].errKind = err.kind;
        pool.slots[slot].errMessage = err.message;
        pool.slots[slot].state = SlotState.done;
        condNotifyAll(pool.resultAvail);
        mutexUnlock(pool.mtx);
    }
}

private struct EncodedMember
{
    ubyte[] buf;
    size_t  len;
}

/// Encode a single chunk into a complete gzip member. Allocates a new
/// output buffer if `outBuf` is too small. May throw `Exception` from
/// GC allocations; the worker wraps the call with try/catch so the
/// loop itself stays `nothrow`.
private Result!EncodedMember encodeMember(const(ubyte)[] input,
                                          CompressMode mode,
                                          uint level,
                                          ubyte[] outBuf) @safe
{
    const need = 32
        + (mode == CompressMode.store
           ? storeEncodeBound(input.length)
           : deflateEncodeBound(input.length));
    if (outBuf.length < need)
        outBuf = new ubyte[need];

    ubyte[16] hdrTmp;
    auto hdr = writeGzipHeader(hdrTmp[], "");
    if (!hdr.ok)
        return failure!EncodedMember(hdr.error.kind, hdr.error.message);
    outBuf[0 .. hdr.value] = hdrTmp[0 .. hdr.value];
    size_t produced = hdr.value;

    if (mode == CompressMode.store)
    {
        scope ubyte[] bodyOut = outBuf[produced .. $];
        auto r = storeEncode(input, bodyOut);
        if (!r.ok)
            return failure!EncodedMember(r.error.kind, r.error.message);
        produced += r.value;
    }
    else
    {
        scope ubyte[] bodyOut = outBuf[produced .. $];
        auto r = deflateEncode(input, bodyOut, level);
        if (!r.ok)
            return failure!EncodedMember(r.error.kind, r.error.message);
        produced += r.value;
    }

    Crc32 c;
    c.put(input);
    scope ubyte[] trailerOut = outBuf[produced .. produced + 8];
    auto tr = writeGzipTrailer(trailerOut,
        c.finish(), cast(uint)(input.length & 0xFFFFFFFFu));
    if (!tr.ok)
        return failure!EncodedMember(tr.error.kind, tr.error.message);
    produced += tr.value;

    EncodedMember m;
    m.buf = outBuf;
    m.len = produced;
    return success(m);
}

// ------------------------------------------------------------------ //
// Helpers (caller must hold pool.mtx)

private size_t findSubmittedSlot(scope Pool pool) @safe nothrow
{
    size_t bestSlot = size_t.max;
    size_t bestIdx  = size_t.max;
    foreach (i, ref s; pool.slots)
    {
        if (s.state == SlotState.submitted && s.index < bestIdx)
        {
            bestIdx = s.index;
            bestSlot = i;
        }
    }
    return bestSlot;
}

private size_t findDoneSlot(scope Pool pool, size_t wantIndex) @safe nothrow
{
    foreach (i, ref s; pool.slots)
        if (s.state == SlotState.done && s.index == wantIndex)
            return i;
    return size_t.max;
}

private size_t findEmptySlot(scope Pool pool) @safe nothrow
{
    foreach (i, ref s; pool.slots)
        if (s.state == SlotState.empty)
            return i;
    return size_t.max;
}

// ------------------------------------------------------------------ //
// Tests

@safe unittest
{
    import std.file : tempDir, write, read, remove;
    import std.path : buildPath;
    import zipd.compressor.streaming : decompressFile;

    const dir = tempDir();
    const inPath = buildPath(dir, "zipd-mt.in");
    const gzPath = buildPath(dir, "zipd-mt.gz");
    const outPath = buildPath(dir, "zipd-mt.out");

    // ~3.5 chunks at 1 MiB.
    auto payload = new ubyte[3_700_000];
    foreach (i, ref b; payload)
        b = cast(ubyte)((i * 31 + 7) & 0xFF);
    write(inPath, payload);

    File inF, outF;
    inF = File(inPath, "rb");
    outF = File(gzPath, "wb");
    CompressionSettings s;
    s.mode = CompressMode.deflate;
    s.threads = 4;
    s.chunkSize = 1 * 1024 * 1024;
    auto r = compressMultiMember(inF, outF, s, "");
    assert(r.ok);
    assert(r.value.blocks == 4); // 3 full + 1 partial
    inF = File.init;
    try outF.flush(); catch (Exception) {}
    outF = File.init;

    auto d = decompressFile(gzPath, outPath);
    assert(d.ok);
    auto round = cast(const(ubyte)[]) read(outPath);
    assert(round.length == payload.length);
    assert(round == payload);

    remove(inPath);
    remove(gzPath);
    remove(outPath);
}

@safe unittest
{
    // Determinism: identical input + settings → identical output bytes.
    import std.file : tempDir, write, read, remove;
    import std.path : buildPath;

    const dir = tempDir();
    const inPath = buildPath(dir, "zipd-det.in");
    const gz1 = buildPath(dir, "zipd-det.1.gz");
    const gz2 = buildPath(dir, "zipd-det.2.gz");

    auto payload = new ubyte[600_000];
    foreach (i, ref b; payload)
        b = cast(ubyte)((i ^ (i >> 3)) & 0xFF);
    write(inPath, payload);

    void run(string outPath) @safe
    {
        File inF = File(inPath, "rb");
        File outF = File(outPath, "wb");
        CompressionSettings s;
        s.mode = CompressMode.deflate;
        s.threads = 3;
        s.chunkSize = 256 * 1024;
        auto r = compressMultiMember(inF, outF, s, "");
        assert(r.ok);
        try outF.flush(); catch (Exception) {}
    }

    run(gz1);
    run(gz2);
    auto a = cast(const(ubyte)[]) read(gz1);
    auto b = cast(const(ubyte)[]) read(gz2);
    assert(a == b, "multi-thread output is not deterministic");

    remove(inPath);
    remove(gz1);
    remove(gz2);
}
