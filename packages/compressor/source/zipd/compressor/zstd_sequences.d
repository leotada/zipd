/**
 * Shared sequence helpers for the ZSTD encoder and decoder.
 *
 * Holds the repeat-offset state machine so both directions use exactly
 * the same transitions (RFC 8878 §3.1.1.5).
 */
module zipd.compressor.zstd_sequences;

@safe:

/// A sequence as stored in the bitstream: literal run, match length
/// (>= 3) and the *coded* offset value (1..3 = repeat, else offset + 3).
struct ZstdSeq
{
    uint litLength;
    uint matchLength;
    uint offsetValue;
}

/// Initial repeat offsets at every frame start.
enum uint[3] initialRep = [1, 4, 8];

/// Decoder direction: turn a coded `offsetValue` into a real offset and
/// update `rep`. Returns false if the offset would be zero.
bool resolveOffset(uint offsetValue, uint litLen, ref uint[3] rep,
    out uint offset) pure nothrow @nogc
{
    if (offsetValue > 3)
    {
        offset = offsetValue - 3;
        rep[2] = rep[1];
        rep[1] = rep[0];
        rep[0] = offset;
        return true;
    }
    const idx = offsetValue + (litLen == 0 ? 1 : 0);
    if (idx == 1)
        offset = rep[0];
    else if (idx == 2)
    {
        offset = rep[1];
        rep[1] = rep[0];
        rep[0] = offset;
    }
    else if (idx == 3)
    {
        offset = rep[2];
        rep[2] = rep[1];
        rep[1] = rep[0];
        rep[0] = offset;
    }
    else
    {
        offset = rep[0] - 1;
        if (offset == 0)
            return false;
        rep[2] = rep[1];
        rep[1] = rep[0];
        rep[0] = offset;
    }
    return true;
}

/// True if `offset` can be coded as a repeat offset for this `litLen`.
bool isRepeatOffset(uint litLen, uint offset, scope const ref uint[3] rep)
    pure nothrow @nogc
{
    if (litLen > 0)
        return offset == rep[0] || offset == rep[1] || offset == rep[2];
    return offset == rep[1] || offset == rep[2]
        || (rep[0] > 1 && offset == rep[0] - 1);
}

/// Encoder direction: pick the coded value for `offset` and update `rep`
/// exactly as `resolveOffset` will on the decoder side.
uint encodeOffset(uint litLen, uint offset, ref uint[3] rep) pure nothrow @nogc
{
    if (litLen > 0)
    {
        if (offset == rep[0])
            return 1;
        if (offset == rep[1])
        {
            rep[1] = rep[0];
            rep[0] = offset;
            return 2;
        }
        if (offset == rep[2])
        {
            rep[2] = rep[1];
            rep[1] = rep[0];
            rep[0] = offset;
            return 3;
        }
    }
    else
    {
        if (offset == rep[1])
        {
            rep[1] = rep[0];
            rep[0] = offset;
            return 1;
        }
        if (offset == rep[2])
        {
            rep[2] = rep[1];
            rep[1] = rep[0];
            rep[0] = offset;
            return 2;
        }
        if (rep[0] > 1 && offset == rep[0] - 1)
        {
            rep[2] = rep[1];
            rep[1] = rep[0];
            rep[0] = offset;
            return 3;
        }
    }
    rep[2] = rep[1];
    rep[1] = rep[0];
    rep[0] = offset;
    return offset + 3;
}

@safe unittest
{
    // Encoder and decoder repeat-offset state stay in lockstep.
    uint[3] e = initialRep, d = initialRep;
    uint seed = 12345;
    foreach (i; 0 .. 20_000)
    {
        seed = seed * 1103515245 + 12345;
        const litLen = (seed >> 16) % 3 == 0 ? 0 : (seed >> 8) % 7;
        // Bias towards recent offsets so repeat codes get exercised.
        uint offset;
        switch ((seed >> 4) % 6)
        {
            case 0: offset = e[0]; break;
            case 1: offset = e[1]; break;
            case 2: offset = e[2]; break;
            case 3: offset = e[0] > 1 ? e[0] - 1 : 5; break;
            default: offset = 1 + (seed >> 12) % 5000; break;
        }
        const val = encodeOffset(litLen, offset, e);
        uint got;
        assert(resolveOffset(val, litLen, d, got));
        assert(got == offset);
        assert(e == d);
    }
}

@safe unittest
{
    uint[3] rep = [1, 4, 8];
    uint o;
    // ll == 0, value 3 with rep0 == 1 is the zero-offset corruption.
    assert(!resolveOffset(3, 0, rep, o));
    rep = [1, 4, 8];
    assert(resolveOffset(1, 5, rep, o) && o == 1);
    assert(resolveOffset(2, 0, rep, o) && o == 8 && rep == [8, 1, 4]);
}
