# Benchmark Results

- Host threads: 16
- Chunk size: 1m
- Runs per case: 1
- Data dir: /home/leonardo/Projetos/zipd/tools/benchmark-data

| Dataset | Threads | Avg time | Throughput | Output ratio |
| --- | ---: | ---: | ---: | ---: |
| Compressible, 128 MiB | 1 | 0.7994 s | 160.12 MiB/s | 0.82% |
| Compressible, 128 MiB | 2 | 0.3792 s | 337.55 MiB/s | 0.83% |
| Compressible, 128 MiB | 4 | 0.2040 s | 627.45 MiB/s | 0.83% |
| Compressible, 128 MiB | auto (0) | 0.0887 s | 1443.07 MiB/s | 0.83% |
| Mixed, 128 MiB | 1 | 1.1252 s | 113.76 MiB/s | 10.51% |
| Mixed, 128 MiB | 2 | 0.5707 s | 224.29 MiB/s | 10.55% |
| Mixed, 128 MiB | 4 | 0.2946 s | 434.49 MiB/s | 10.55% |
| Mixed, 128 MiB | auto (0) | 0.1333 s | 960.24 MiB/s | 10.55% |
| LCG binary, 64 MiB | 1 | 1.7740 s | 36.08 MiB/s | 105.44% |
| LCG binary, 64 MiB | 2 | 0.8993 s | 71.17 MiB/s | 105.45% |
| LCG binary, 64 MiB | 4 | 0.4790 s | 133.61 MiB/s | 105.45% |
| LCG binary, 64 MiB | auto (0) | 0.2137 s | 299.49 MiB/s | 105.45% |

### Accumulated GC Profile

- **Collections (runs):** 27
- **Max Pause:** 972 hnsecs
- **Total Pause:** 51 hnsecs
