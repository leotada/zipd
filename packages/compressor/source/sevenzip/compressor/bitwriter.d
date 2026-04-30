/**
 * LSB-first bit writer for DEFLATE streams.
 *
 * RFC 1951 §3.1.1 specifies that data elements other than Huffman codes
 * are packed starting with the least significant bit of the data
 * element. Huffman codes are packed starting with the most significant
 * bit of the code. This writer accepts pre-reversed Huffman codes from
 * `huffman.d` so that all bits enter the bit buffer LSB-first.
 *
 * Phase 1 only emits BTYPE=00 (stored) blocks, which use the simple
 * "byte-align, length, ~length, payload" scheme; the bit writer is
 * still useful for the 3-bit block header.
 */
module sevenzip.compressor.bitwriter;

import sevenzip.compressor.errors : Result, ErrorKind, success, failure;

@safe:

/// Slice-backed bit writer. Owns no memory; writes into a caller buffer.
struct BitWriter
{
    private ubyte[] buf;
    private size_t  pos;     // next byte index to write
    private uint    bitBuf;  // pending bits, LSB-first
    private uint    bitCount;

    /// Construct a writer over `output`. The caller owns `output` and is
    /// responsible for sizing it large enough for the data to be written.
    this(return scope ubyte[] output) pure nothrow @nogc @safe return scope
    {
        this.buf = output;
        this.pos = 0;
        this.bitBuf = 0;
        this.bitCount = 0;
    }

    /// Bytes written so far, including the partial byte currently held
    /// in the bit buffer (rounded up).
    size_t bytesWritten() const pure nothrow @nogc @safe scope
    {
        return pos + (bitCount > 0 ? 1 : 0);
    }

    /// Bytes flushed to the output slice (excludes the held bit buffer).
    size_t bytesFlushed() const pure nothrow @nogc @safe scope { return pos; }

    /// Append `nBits` low-order bits of `value` to the stream.
    /// `nBits` must be <= 24.
    Result!size_t writeBits(uint value, uint nBits) pure nothrow @nogc @safe scope
    {
        assert(nBits <= 24, "writeBits supports up to 24 bits per call");
        bitBuf |= (value & ((1u << nBits) - 1u)) << bitCount;
        bitCount += nBits;
        while (bitCount >= 8)
        {
            if (pos >= buf.length)
                return failure!size_t(ErrorKind.internal,
                    "bit writer output buffer overflow");
            buf[pos++] = cast(ubyte)(bitBuf & 0xFFu);
            bitBuf >>= 8;
            bitCount -= 8;
        }
        return success(pos);
    }

    /// Flush pending bits, padding the trailing byte with zeros.
    Result!size_t flushToByteBoundary() pure nothrow @nogc @safe scope
    {
        if (bitCount > 0)
        {
            if (pos >= buf.length)
                return failure!size_t(ErrorKind.internal,
                    "bit writer output buffer overflow on flush");
            buf[pos++] = cast(ubyte)(bitBuf & 0xFFu);
            bitBuf = 0;
            bitCount = 0;
        }
        return success(pos);
    }

    /// Append `data` byte-for-byte. Caller must have flushed to a byte
    /// boundary first; asserts otherwise.
    Result!size_t writeBytes(scope const(ubyte)[] data) pure nothrow @nogc @safe scope
    {
        assert(bitCount == 0, "writeBytes requires byte-aligned writer");
        if (data.length > buf.length - pos)
            return failure!size_t(ErrorKind.internal,
                "bit writer output buffer overflow on writeBytes");
        buf[pos .. pos + data.length] = data[];
        pos += data.length;
        return success(pos);
    }
}

@safe unittest
{
    ubyte[8] storage;
    auto w = BitWriter(storage[]);

    // Write three 1-bit values: 1, 0, 1 → byte 0b00000101 = 0x05.
    assert(w.writeBits(1, 1).ok);
    assert(w.writeBits(0, 1).ok);
    assert(w.writeBits(1, 1).ok);
    assert(w.flushToByteBoundary().ok);
    assert(w.bytesFlushed == 1);
    assert(storage[0] == 0b00000101);
}

@safe unittest
{
    ubyte[16] storage;
    auto w = BitWriter(storage[]);
    // 16 bits → 2 bytes, no flush needed.
    assert(w.writeBits(0xABCD, 16).ok);
    assert(w.bytesFlushed == 2);
    // LSB-first: low byte first.
    assert(storage[0] == 0xCD);
    assert(storage[1] == 0xAB);
}

@safe unittest
{
    ubyte[8] storage;
    auto w = BitWriter(storage[]);
    auto r = w.writeBits(0, 1);
    assert(r.ok);
    auto bytes = w.flushToByteBoundary();
    assert(bytes.ok);
    assert(w.writeBytes([cast(ubyte) 0xDE, cast(ubyte) 0xAD]).ok);
    assert(storage[0] == 0x00);
    assert(storage[1] == 0xDE);
    assert(storage[2] == 0xAD);
}
