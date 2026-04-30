/**
 * Public façade for the `compressor` package.
 *
 * Re-exports the API the CLI and library users need.
 */
module zipd.compressor;

public import zipd.compressor.errors;
public import zipd.compressor.settings;
public import zipd.compressor.streaming : compressFile, decompressFile;
