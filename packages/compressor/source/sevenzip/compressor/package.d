/**
 * Public façade for the `compressor` package.
 *
 * Re-exports the API the CLI and library users need.
 */
module sevenzip.compressor;

public import sevenzip.compressor.errors;
public import sevenzip.compressor.settings;
public import sevenzip.compressor.streaming : compressFile, decompressFile;
