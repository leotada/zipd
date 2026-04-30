# Benchmark Results

- Host threads: 16
- Chunk size: 1m
- Runs per case: 1
- Data dir: /home/leonardo/Projetos/7zip/sevenzip-safe-d/tools/benchmark-data

| Dataset | Threads | Avg time | Throughput | Output ratio |
| --- | ---: | ---: | ---: | ---: |
| Compressible, 128 MiB | 1 | 1.0488 s | 122.04 MiB/s | 0.82% |
| Compressible, 128 MiB | 2 | 0.4093 s | 312.73 MiB/s | 0.83% |
| Compressible, 128 MiB | 4 | 0.2127 s | 601.79 MiB/s | 0.83% |
| Compressible, 128 MiB | auto (0) | 0.0954 s | 1341.72 MiB/s | 0.83% |
| Mixed, 128 MiB | 1 | 1.3359 s | 95.82 MiB/s | 10.51% |
| Mixed, 128 MiB | 2 | 0.6045 s | 211.75 MiB/s | 10.55% |
| Mixed, 128 MiB | 4 | 0.3200 s | 400.00 MiB/s | 10.55% |
| Mixed, 128 MiB | auto (0) | 0.1431 s | 894.48 MiB/s | 10.55% |
| LCG binary, 64 MiB | 1 | 1.7677 s | 36.21 MiB/s | 105.44% |
| LCG binary, 64 MiB | 2 | 0.8795 s | 72.77 MiB/s | 105.45% |
| LCG binary, 64 MiB | 4 | 0.4678 s | 136.81 MiB/s | 105.45% |
| LCG binary, 64 MiB | auto (0) | 0.2060 s | 310.68 MiB/s | 105.45% |
