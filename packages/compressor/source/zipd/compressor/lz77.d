/**
 * LZ77 hash-chain match finder for DEFLATE encoding.
 *
 * Operates on a single contiguous input slice (the entire input being
 * encoded, up to the 1 GiB soft cap). The hash table and chain links
 * are sized for a 32 KiB window per RFC 1951; chain depth is capped to
 * keep encode time predictable.
 *
 * Pure `@safe` and `@nogc` apart from the tables (which are heap
 * arrays allocated once at construction). No `@trusted`.
 */
module zipd.compressor.lz77;

@safe:

/// 32 KiB sliding window — RFC 1951's maximum back-reference distance.
enum size_t windowSize = 1u << 15;
/// Mask to wrap a position into the rolling window arrays.
enum size_t windowMask = windowSize - 1;
/// Hash table size (15-bit hash). Same magnitude as the window.
enum size_t hashSize = 1u << 15;
/// Hash mask.
enum size_t hashMask = hashSize - 1;

/// Minimum match length DEFLATE can encode.
enum uint minMatch = 3;
/// Maximum match length DEFLATE can encode.
enum uint maxMatch = 258;

/// "No previous position" sentinel. We use uint.max so that any valid
/// position (which is < input.length) fits without collision.
enum uint noPrev = uint.max;

/// A match found by the hash-chain search.
struct Match
{
    uint length;   /// 0 if no match >= minMatch
    uint distance; /// only meaningful when length >= minMatch
}

/**
 * Hash-chain match finder.
 *
 * Lifetime: the `data` slice given to `init` must outlive the matcher;
 * borrowed via `scope` semantics.
 */
struct Lz77Matcher
{
    private const(ubyte)[] data;
    private uint[hashSize] head;     // hash → most recent position with that hash
    private uint[windowSize] chain;    // position-mod-windowSize → previous position
    private uint maxChain;   // chain walk cap (compression effort)

    /// Allocate the tables and bind to `data`. `level` 1..9 maps to a
    /// chain-walk cap; level 0 means store-only and is not used here.
    void init(const(ubyte)[] data, uint level) @safe scope
    {
        this.data = data;
        head[]  = noPrev;
        chain[] = noPrev;
        maxChain = chainForLevel(level);
    }

    /// Map compression level (1..9) to a chain-walk cap. Mirrors
    /// zlib's "max_chain_length" table closely enough for our needs.
    static uint chainForLevel(uint level) pure nothrow @nogc @safe
    {
        // zlib defaults: 1=4, 2=8, 3=32, 4=16, 5=32, 6=128, 7=256, 8=1024, 9=4096
        static immutable uint[10] table = [
            0,    // unused (level 0 = store)
            4, 8, 32, 16, 32, 128, 256, 1024, 4096
        ];
        if (level == 0) return 0;
        if (level > 9) level = 9;
        return table[level];
    }

    /// 3-byte hash. Standard DEFLATE-style multiplicative-mix
    /// reduced to `hashBits` bits.
    private uint hash3(size_t pos) const pure nothrow @nogc @safe scope
    {
        const a = data[pos];
        const b = data[pos + 1];
        const c = data[pos + 2];
        return ((cast(uint) a << 10) ^ (cast(uint) b << 5)
            ^ cast(uint) c) & cast(uint) hashMask;
    }

    /// Insert position `pos` into the hash chain. Requires that
    /// `pos + minMatch <= data.length`.
    void insert(size_t pos) pure nothrow @nogc @safe scope
    {
        const h = hash3(pos);
        chain[pos & windowMask] = head[h];
        head[h] = cast(uint) pos;
    }

    /// Look up the longest match at `pos`. Returns `Match(0, 0)` if no
    /// match of length >= `minMatch` is available. Also inserts `pos`
    /// into the hash chain.
    Match findLongest(size_t pos) pure nothrow @nogc @safe scope
    {
        Match best;
        if (pos + minMatch > data.length)
        {
            // Too close to end-of-input to match; still insert if we can.
            return best;
        }

        const uint maxLen = cast(uint)
            (data.length - pos > maxMatch ? maxMatch : data.length - pos);

        const h = hash3(pos);
        uint cand = head[h];

        // Insert this position before walking; helps for long match
        // self-extension at this same hash bucket.
        chain[pos & windowMask] = cand;
        head[h] = cast(uint) pos;

        const uint posU = cast(uint) pos;
        const size_t minPos = pos > windowSize ? pos - windowSize : 0;
        uint walks = 0;
        while (cand != noPrev && cand < posU && cand >= minPos
            && walks < maxChain)
        {
            walks++;
            // Quick reject: compare the would-be last byte first.
            // Guarded by `best.length < maxLen` so the index is in
            // range (cand < pos, so cand + best.length < data.length
            // automatically when best.length < maxLen).
            if (best.length >= minMatch
                && best.length < maxLen
                && data[cand + best.length] != data[pos + best.length])
            {
                cand = chain[cand & windowMask];
                continue;
            }
            // Count common prefix.
            uint k = 0;
            while (k < maxLen && data[cand + k] == data[pos + k])
                k++;
            if (k >= minMatch && k > best.length)
            {
                best.length = k;
                best.distance = posU - cand;
                if (k == maxMatch || k == maxLen)
                    break; // can't extend further
            }
            cand = chain[cand & windowMask];
        }
        return best;
    }
}

@safe unittest
{
    // Find a self-overlap match.
    immutable ubyte[] data = cast(immutable(ubyte)[])
        "abcabcabcabcabc";
    Lz77Matcher m;
    m.init(data, 6);
    foreach (i; 0 .. 3)
        m.insert(i);
    auto match = m.findLongest(3);
    assert(match.length >= 3);
    assert(match.distance == 3);
}

@safe unittest
{
    immutable ubyte[] data = cast(immutable(ubyte)[]) "no repetition here!";
    Lz77Matcher m;
    m.init(data, 6);
    // Don't pre-insert pos 0; findLongest will do it.
    auto match = m.findLongest(0);
    assert(match.length == 0);
}
