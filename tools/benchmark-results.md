# Benchmark Results

- Host threads: 16
- Chunk size: 1m
- Runs per case: 3
- Data dir: /home/leonardo/Projetos/zipd/tools/benchmark-data

| Dataset | Threads | Avg time | Throughput | Output ratio |
| --- | ---: | ---: | ---: | ---: |
| Compressible, 128 MiB | 1 | 0.6563 s | 195.03 MiB/s | 0.97% |
| Compressible, 128 MiB | 2 | 0.2380 s | 537.82 MiB/s | 0.98% |
| Compressible, 128 MiB | 4 | 0.1228 s | 1042.35 MiB/s | 0.98% |
| Compressible, 128 MiB | auto (0) | 0.0671 s | 1907.60 MiB/s | 0.98% |
| Mixed, 128 MiB | 1 | 0.9691 s | 132.08 MiB/s | 10.60% |
| Mixed, 128 MiB | 2 | 0.3930 s | 325.70 MiB/s | 10.64% |
| Mixed, 128 MiB | 4 | 0.2138 s | 598.69 MiB/s | 10.64% |
| Mixed, 128 MiB | auto (0) | 0.1124 s | 1138.79 MiB/s | 10.64% |
| LCG binary, 64 MiB | 1 | 1.4933 s | 42.86 MiB/s | 105.44% |
| LCG binary, 64 MiB | 2 | 0.7737 s | 82.72 MiB/s | 105.45% |
| LCG binary, 64 MiB | 4 | 0.4014 s | 159.44 MiB/s | 105.45% |
| LCG binary, 64 MiB | auto (0) | 0.2018 s | 317.15 MiB/s | 105.45% |

### Accumulated GC Profile

- **Collections (runs):** 6
- **Max Pause:** 366 hnsecs
- **Total Pause:** 0 hnsecs
