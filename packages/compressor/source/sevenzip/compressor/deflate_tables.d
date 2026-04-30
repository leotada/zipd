/**
 * Constant tables for DEFLATE (RFC 1951).
 *
 * - Length codes 257..285 with their base lengths and extra-bit counts.
 * - Distance codes 0..29 with their base distances and extra-bit counts.
 * - The fixed-Huffman code lengths for the literal/length and distance
 *   alphabets (BTYPE=01).
 * - The order in which the 19 code-length-code lengths are transmitted
 *   inside dynamic-Huffman (BTYPE=10) headers.
 */
module sevenzip.compressor.deflate_tables;

@safe:

/// End-of-block marker symbol in the literal/length alphabet.
enum int endOfBlock = 256;

/// Number of length codes (257..285 inclusive).
enum uint numLengthCodes = 29;

/// Number of distance codes (0..29 inclusive).
enum uint numDistanceCodes = 30;

/// Base length for length code (`code - 257`).
immutable ushort[numLengthCodes] lengthBase = [
      3,   4,   5,   6,   7,   8,   9,  10,
     11,  13,  15,  17,  19,  23,  27,  31,
     35,  43,  51,  59,  67,  83,  99, 115,
    131, 163, 195, 227, 258
];

/// Number of extra bits to read for length code (`code - 257`).
immutable ubyte[numLengthCodes] lengthExtraBits = [
    0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4,
    5, 5, 5, 5, 0
];

/// Base distance for distance code.
immutable ushort[numDistanceCodes] distanceBase = [
        1,    2,    3,    4,     5,     7,     9,    13,
       17,   25,   33,   49,    65,    97,   129,   193,
      257,  385,  513,  769,  1025,  1537,  2049,  3073,
     4097, 6145, 8193, 12289, 16385, 24577
];

/// Number of extra bits to read for distance code.
immutable ubyte[numDistanceCodes] distanceExtraBits = [
    0,  0,  0,  0,  1,  1,  2,  2,
    3,  3,  4,  4,  5,  5,  6,  6,
    7,  7,  8,  8,  9,  9, 10, 10,
   11, 11, 12, 12, 13, 13
];

/// Order in which the code-length-code lengths appear in dynamic
/// Huffman headers, per RFC 1951 §3.2.7.
immutable ubyte[19] codeLengthOrder = [
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15
];

/// Number of literal/length codes in the fixed-Huffman alphabet (288).
enum uint fixedLitLenCount = 288;

/// Number of distance codes in the fixed-Huffman alphabet (32).
enum uint fixedDistCount = 32;

/// Build the fixed-Huffman code-length array for the literal/length
/// alphabet at compile time.
immutable(ubyte)[fixedLitLenCount] fixedLitLenLengths = () {
    ubyte[fixedLitLenCount] a;
    foreach (i; 0 .. 144)   a[i] = 8;
    foreach (i; 144 .. 256) a[i] = 9;
    foreach (i; 256 .. 280) a[i] = 7;
    foreach (i; 280 .. 288) a[i] = 8;
    return a;
}();

/// Fixed-Huffman code-length array for the distance alphabet: all 5.
immutable(ubyte)[fixedDistCount] fixedDistLengths = () {
    ubyte[fixedDistCount] a;
    foreach (ref x; a) x = 5;
    return a;
}();
