# Reference-frame batching benchmark — 2026-11-21

Baseline: batched sampling (`138294e`). Candidate: `721fb40`. Same synthetic corpus, FFmpeg 9.0.2, macOS 26.6.2 arm64, one warm-up and five alternating measured runs. Exact normalized analysis and decoded RGB PNG parity passed on every run. See the sampling report for methodology; this remains a shared-workstation core benchmark, not app latency or native ScreenCaptureKit QA.

| Case | Sampling-only median (s) | Batched references median (s) | FFmpeg processes before / after |
|---|---:|---:|---:|
| motion | 0.168 | 0.122 | 4 / 2 |
| static | 0.121 | 0.122 | 2 / 2 |
| sparse | 0.148 | 0.120 | 4 / 2 |
| offset | 0.169 | 0.124 | 4 / 2 |
| portrait | 0.169 | 0.121 | 4 / 2 |
| short | 0.132 | 0.124 | 2 / 2 |
| hd | 0.954 | 1.061 | 4 / 2 |
| overrun | 0.333 | 0.277 | 5 / 3 |

Full ranges, CPU, process counts and separately sampled parent/largest-child RSS are in the adjacent JSON. Reference batching reduces process count but is not uniformly faster: sequentially decoding again costs more than a few targeted seeks on this 1080p clip (0.954 to 1.061 seconds). Treat this as a reviewable tradeoff; the first PR delivers the main measured gain. Ordinary inspections use one sampling process and one reference process; recorder-overrun normalization adds an encoding process.

Reproduce with built sampling-only and reference-batching checkouts: `python3 scripts/bench/compare.py SAMPLING_ROOT REFERENCES_ROOT 5`.
