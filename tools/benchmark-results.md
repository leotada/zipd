# Benchmark Results

- Host threads: 16
- Chunk size: 1m
- Runs per case: 1
- Data dir: /home/leonardo/Projetos/zipd/tools/benchmark-data

| Dataset | Threads | Avg time | Throughput | Output ratio |
| --- | ---: | ---: | ---: | ---: |
| Compressible, 128 MiB | 1 | 0.8120 s | 157.64 MiB/s | 0.82% |
| Compressible, 128 MiB | 2 | 0.3732 s | 342.98 MiB/s | 0.83% |
| Compressible, 128 MiB | 4 | 0.2049 s | 624.69 MiB/s | 0.83% |
| Compressible, 128 MiB | auto (0) | 0.0941 s | 1360.26 MiB/s | 0.83% |
| Mixed, 128 MiB | 1 | 1.1502 s | 111.28 MiB/s | 10.51% |
| Mixed, 128 MiB | 2 | 0.5594 s | 228.82 MiB/s | 10.55% |
| Mixed, 128 MiB | 4 | 0.3021 s | 423.70 MiB/s | 10.55% |
| Mixed, 128 MiB | auto (0) | 0.1371 s | 933.63 MiB/s | 10.55% |
| LCG binary, 64 MiB | 1 | 1.7117 s | 37.39 MiB/s | 105.44% |
| LCG binary, 64 MiB | 2 | 0.8988 s | 71.21 MiB/s | 105.45% |
| LCG binary, 64 MiB | 4 | 0.4509 s | 141.94 MiB/s | 105.45% |
| LCG binary, 64 MiB | auto (0) | 0.2130 s | 300.47 MiB/s | 105.45% |

### Accumulated GC Profile

- **Collections (runs):** 27
- **Max Pause:** 940 hnsecs
- **Total Pause:** 47 hnsecs
