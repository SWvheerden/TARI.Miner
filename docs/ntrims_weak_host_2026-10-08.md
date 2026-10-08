# ntrims above 50 for CPU-limited hosts: RTX 4080, 2026-10-08

Does running more trim rounds than the default 50 help mining hosts whose CPU,
not GPU, is the bottleneck? More rounds cost GPU time but leave fewer edges for
the host's cycle search. Everything was measured locally with the solver
(`tari_c29_solver_sm_89`, `--ntrims N` at runtime); no pool or external service
was used. Raw logs stayed on the test machine (`bench\`, not committed).

**Result: (b).** Keep the default at 50. Recommend `--ntrims 60` as an extra
argument on hosts where the CPU limits throughput (weak CPU, many GPUs). It
costs 0.78% on a host with CPU to spare, cuts the host CPU work per graph by
about 30%, and its proof set is identical to the reference's.

## Environment

| | |
|---|---|
| GPU | NVIDIA GeForce RTX 4080, 16 GB, driver 617.14, 340 W default power limit, clocks not locked |
| CUDA | 13.4 (nvcc V13.4.59), MSVC VS 18 Build Tools |
| CPU | Intel Core i5-13600KF, 14 cores (6 P + 8 E) / 20 threads, base 3.5 GHz, about 4.2 GHz effective at idle (`% Processor Performance`), Balanced power plan, max processor state 100% |
| OS | Windows 11 Home 10.0.26200 |
| Build | `969ebca` (main), release profile from `build_flags/sm_89.flags` (`-DSEEDA_CHECKPOINT=32`), `TARI_ARCH_FLAGS` unset |

**Benchmark protocol:** 60 s warm-up, then 3 runs of `--count 2000` back to
back, median `graphs/s`, auto pipeline (2 contexts on this card). Every run
recorded `graphs/s`, `surviving edges`, `cycle search ms`, `cpu busy` and
`lost edges` from the solver summary. No run of this study lost edges:
`oops_graphs=0 node_overflow_graphs=0` and `verify failures: 0` everywhere.

**CPU cores per GPU** = `search_ms_mean / 1000 × g/s`: the share of one core
that the cycle search on the miner's main thread needs to keep one GPU at full
speed.

## Part 1: desktop curve

`bin\tari_c29_solver_sm_89.exe --count 2000 --ntrims N`, whole CPU available.
Drift check: ntrims 50 re-run at the end gave 13.795 g/s (+0.09%).

| ntrims | g/s median (runs) | vs 50 | edges p50 / p99 / max | max % of MAXEDGES | search ms mean / p99 | busy fraction | oops / overflow graphs | CPU cores per GPU |
|---|---|---|---|---|---|---|---|---|
| 50 | 13.782 (13.718 13.783 13.782) | | 775,411 / 791,462 / 803,598 | 76.6% | 29.96 / 38.59 | 0.412 | 0 / 0 | 0.413 |
| 52 | 13.764 (13.764 13.764 13.766) | -0.13% | 719,329 / 735,388 / 746,973 | 71.2% | 27.57 / 33.94 | 0.380 | 0 / 0 | 0.379 |
| 54 | 13.739 (13.743 13.739 13.736) | -0.31% | 669,126 / 684,821 / 696,196 | 66.4% | 25.55 / 31.89 | 0.351 | 0 / 0 | 0.351 |
| 56 | 13.720 (13.720 13.718 13.720) | -0.45% | 623,978 / 639,646 / 650,457 | 62.0% | 23.99 / 29.75 | 0.329 | 0 / 0 | 0.329 |
| 60 | 13.675 (13.675 13.680 13.674) | -0.78% | 546,342 / 561,566 / 571,798 | 54.5% | 20.71 / 26.56 | 0.283 | 0 / 0 | 0.283 |
| 64 | 13.637 (13.637 13.634 13.642) | -1.05% | 482,415 / 497,457 / 506,589 | 48.3% | 18.32 / 24.13 | 0.250 | 0 / 0 | 0.250 |

Each extra pair of rounds removes about 7% of the surviving edges and costs
about 0.1% of g/s. From 50 to 60 the host search time per graph drops 31% and
the `MAXEDGES` headroom grows from 23% to 45%.

**GPU cost per round** (`-DSEEDA_CHECKPOINT=32 -DTRIM_STAGE_TIMING=1` build,
`--count 200 --pipeline 1`, mean of graphs 11 to 200, ms):

| ntrims | SeedA | SeedB | R0 | R1 | R2 | R3 | late | tail | total | surviving edges mean / max |
|---|---|---|---|---|---|---|---|---|---|---|
| 50 | 11.654 | 14.341 | 18.648 | 7.122 | 3.728 | 2.533 | 13.290 | 0.224 | 71.540 | 775,648 / 803,598 |
| 60 | 11.650 | 14.350 | 18.706 | 7.889 | 3.718 | 2.517 | 13.887 | 0.222 | 72.939 | 546,631 / 571,798 |

The 10 extra rounds add 0.60 ms to the late stage, about 0.12 ms per pair:
the late rounds run on few edges and are cheap. The total grows 1.40 ms
(2.0%); part of that is the R1 difference, which these runs cannot separate
from noise. With 2 contexts overlapping, the g/s cost (0.78%) is smaller than
the serialized stage cost.

## Part 2: weak-host behaviour (2b, emulated on the RTX 4080 machine)

No real weak host was available, so this is **2b**, with two deviations from
the brief, both described below:

- **No 50% CPU cap.** Capping the CPU needs a change to the Windows power plan,
  which was left to the user; they chose to skip the capped runs. The
  half-speed numbers below are therefore an **estimate** (measured search time
  × 2), not a measurement.
- **K = 3 and 4 solvers on one GPU could not run.** Each solver context takes
  about 5.9 GB of VRAM (measured: 1,214 MiB idle, 7,091 with one solver,
  12,969 with two). Three or four exceed the 16 GB card; Windows then pages GPU
  memory and every process fell to 0.56 g/s (four at once: 0.560, 0.572,
  0.554, 0.562 g/s), which leaves the CPU idle and measures nothing about CPU
  contention. Only K = 2 was run.

All 2b runs pin the solver with a process affinity mask, inherited by the
solver: mask 5 = logical CPUs 0 and 2, two different P-cores (this CPU numbers
SMT siblings next to each other); mask 1 = one P-core.

### Single solver pinned to 2 cores (mask 5), full clock

| ntrims | g/s median (runs) | vs 50 | search ms mean / p99 | busy | CPU cores per GPU | g/s vs desktop |
|---|---|---|---|---|---|---|
| 50 | 13.787 (13.789 13.786 13.787) | | 29.25 / 35.04 | 0.403 | 0.403 | +0.04% |
| 52 | 13.762 (13.762 13.766 13.757) | -0.18% | 27.02 / 32.48 | 0.372 | 0.372 | -0.01% |
| 54 | 13.748 (13.748 13.735 13.748) | -0.28% | 24.42 / 30.81 | 0.336 | 0.336 | +0.07% |
| 56 | 13.723 (13.713 13.723 13.729) | -0.46% | 23.47 / 29.09 | 0.322 | 0.322 | +0.02% |
| 60 | 13.673 (13.679 13.668 13.673) | -0.83% | 20.42 / 25.92 | 0.279 | 0.279 | -0.01% |
| 64 | 13.637 (13.637 13.625 13.647) | -1.09% | 18.00 / 22.93 | 0.245 | 0.246 | +0.00% |

Edges and lost edges are the same as in Part 1 (same graphs; 0 lost).

### Single solver pinned to 1 core (mask 1), full clock

Not in the brief: one core for one GPU is the CPU share each GPU gets in a
2-GPU, 2-core rig, so a g/s drop here would be a direct sign of a CPU limit.

| ntrims | g/s median (runs) | vs 50 | search ms mean / p99 | busy | g/s vs desktop |
|---|---|---|---|---|---|
| 50 | 13.787 (13.791 13.787 13.786) | | 27.83 / 32.21 | 0.384 | +0.04% |
| 52 | 13.767 (13.767 13.771 13.760) | -0.15% | 25.69 / 30.12 | 0.354 | +0.02% |
| 54 | 13.737 (13.737 13.737 13.736) | -0.36% | 23.92 / 28.72 | 0.329 | -0.01% |
| 56 | 13.716 (13.710 13.716 13.721) | -0.51% | 22.13 / 26.53 | 0.303 | -0.03% |
| 60 | 13.671 (13.669 13.672 13.671) | -0.84% | 19.26 / 22.71 | 0.263 | -0.03% |
| 64 | 13.628 (13.631 13.625 13.628) | -1.15% | 16.75 / 20.07 | 0.228 | -0.07% |

One full-speed P-core feeds an RTX 4080 at full speed at every ntrims; the
search is even slightly faster than on two cores (no migration between cores).
A fast core is not a bottleneck for one or two GPUs.

### Two solvers at once on one GPU and the same 2 cores (mask 5), full clock

`--count 2000 --pipeline 1` each, started together. They share the GPU, so
their g/s is not a rig's g/s (together 8.9 to 9.4 g/s, close to one
pipeline-1 context; two processes time-slice the GPU rather than overlap).
`rig cores needed = K × contended search_ms_mean / 1000 × desktop g/s`.

| ntrims | per-process g/s | search ms mean (p1 / p2) | contended mean | busy (p1 / p2) | rig cores needed (K = 2) | CPU-bound (> 1.6)? | max GPUs a 2-core host feeds |
|---|---|---|---|---|---|---|---|
| 50 | 4.521 / 4.521 | 30.10 / 31.32 | 30.71 | 0.136 / 0.142 | 0.85 | no | 3 |
| 52 | 4.462 / 4.463 | 29.36 / 29.96 | 29.66 | 0.131 / 0.134 | 0.82 | no | 3 |
| 54 | 4.584 / 4.584 | 24.71 / 25.93 | 25.32 | 0.113 / 0.119 | 0.70 | no | 4 |
| 56 | 4.631 / 4.632 | 23.10 / 23.76 | 23.43 | 0.107 / 0.110 | 0.64 | no | 4 |
| 60 | 4.657 / 4.657 | 20.78 / 19.66 | 20.22 | 0.097 / 0.091 | 0.55 | no | 5 |
| 64 | 4.698 / 4.698 | 16.88 / 17.94 | 17.41 | 0.079 / 0.084 | 0.47 | no | 6 |

Against the single pinned solver, the contended search time ranges from 3%
lower to 10% higher, with no consistent trend over ntrims. Because the two processes
share one GPU, their combined graph rate (and so their CPU load) is no higher
than one solver's, so this stand-in loads the CPU far less than a real
2-GPU rig would. The ntrims 52 row is a re-run: the PC was put to sleep during
the first attempt (13:19:49 to 13:19:52), whose logs are kept but not used.

### Estimate: how many GPUs a 2-core host can feed

Model: the cycle search runs on each miner's main thread, so a 2-core host
(1.6 cores after about 20% for the OS, driver and the miners' other threads)
can search at most `1.6 × 1000 / search_ms` graphs per second in total. A rig
of K GPUs then makes `min(K × desktop g/s, that cap)`. GPUs here are RTX
4080-class (13.6 to 13.8 g/s each); slower GPUs need proportionally less CPU,
so compare a rig's total graph rate with the CPU cap rather than its GPU count.

Full-speed cores use the measured mask-5 search times. **Half-speed cores are
an estimate**: the same times × 2. That is conservative, because the search is
partly memory-bound and slows down less than the clock.

| ntrims | search ms, full / half speed | cores per GPU, full / half | CPU cap (graphs/s), full / half | max GPUs per 2-core host, full / half |
|---|---|---|---|---|
| 50 | 29.25 / 58.50 | 0.403 / 0.806 | 54.7 / 27.4 | 3 / 1 (3.97 / 1.98) |
| 52 | 27.02 / 54.04 | 0.372 / 0.744 | 59.2 / 29.6 | 4 / 2 (4.30 / 2.15) |
| 54 | 24.42 / 48.84 | 0.336 / 0.671 | 65.5 / 32.8 | 4 / 2 (4.77 / 2.38) |
| 56 | 23.47 / 46.94 | 0.322 / 0.644 | 68.2 / 34.1 | 4 / 2 (4.97 / 2.48) |
| 60 | 20.42 / 40.84 | 0.279 / 0.558 | 78.4 / 39.2 | 5 / 2 (5.73 / 2.86) |
| 64 | 18.00 / 36.00 | 0.245 / 0.491 | 88.9 / 44.4 | 6 / 3 (6.52 / 3.26) |

Estimated rig g/s on a **full-speed** 2-core host (change vs 50):

| GPUs | 50 | 56 | 60 | 64 |
|---|---|---|---|---|
| 1 to 3 | 13.8 / 27.6 / 41.3 | -0.4% | -0.8% | -1.1% |
| 4 | 54.7 | +0.3% | -0.0% | -0.3% |
| 5 | 54.7 | +24.6% | +25.0% | +24.7% |
| 6 | 54.7 | +24.6% | +43.2% | +49.6% |
| 7 or more | 54.7 | +24.6% | +43.2% | +62.5% |

Estimated rig g/s on a **half-speed** 2-core host (change vs 50):

| GPUs | 50 | 56 | 60 | 64 |
|---|---|---|---|---|
| 1 | 13.8 | -0.4% | -0.8% | -1.1% |
| 2 | 27.4 | +0.3% | -0.0% | -0.3% |
| 3 | 27.4 | +24.6% | +43.2% | +49.6% |
| 4 or more | 27.4 | +24.6% | +43.2% | +62.5% |

The pattern: while the GPUs are the limit, every extra pair of rounds costs
about 0.1 to 0.2%; once the CPU is the limit, the rig's graph rate scales with
1 / search time: the search is 20% shorter at 56, 30% at 60 and 38% at 64
(relative to 50), so the CPU cap rises 25%, 43% and 62%.

## Part 3: correctness

`python tests\tari_c29_gpu_recall.py run --candidate bin\tari_c29_solver_sm_89.exe --reference bin\validation\tari_c29_solver_sm_89_reference.exe --arch sm_89 --candidate-ntrims N --output-dir bench\recall_ntrims_N --parity-pipeline 2`
(reference at its normal 50), PC kept awake:

| candidate ntrims | result | proofs (4,200 graphs) | candidate edges max | lost edges |
|---|---|---|---|---|
| 56 | **PASS**: candidate and reference repeatability, candidate vs reference, pipeline 2 parity all identical; no errors | 110 | 650,457 | 0 |
| 60 | **PASS**: same four comparisons identical; no errors | 110 | 571,798 | 0 |

The reference (ntrims 50) found the same 110 proofs in both repeats, with
edges max 803,598 and 0 lost edges. Candidate g/s in the recall runs:
10.21 / 10.37 (pipeline 1) and 13.53 (pipeline 2) at 56; 10.39 / 10.69 and
13.69 at 60.

**Pool miner check:** `tari_c29_pool_miner_sm_89.exe --ntrims 60
--max-runtime-sec 120` against a local test pool on 127.0.0.1 (60 s blocks):
exit 0, `graphs=1645 elapsed=120.11s speed=13.696 g/s cycles=40 submitted=40
verify_failures=0`, all 40 shares accepted, none rejected.

64 was not recall-tested (the brief allows at most two values), so it is not
recommended here even though the model favours it on the most CPU-bound rigs.

## Part 4: recommendation

**(b) Recommend `--ntrims 60` for CPU-limited hosts only; keep the default at 50.**

- **Why not (c), a new sm_89 default.** 56 is the only value under the 0.5%
  desktop limit (-0.45%), and only just. The weak-host gain is estimated, not
  measured (no capped or real weak-host runs), which is too little to change
  the default for every sm_89 user. A host with CPU to spare loses 0.45 to
  0.78% for nothing.
- **Why 60 rather than 56.** On a CPU-bound rig 60 gives about 43% more
  graphs than 50, against about 25% for 56, and widens the `MAXEDGES`
  headroom to 45% (max 571,798 of 1,048,576 edges). Its cost on a host that is
  not CPU-bound is 0.78%. 56 (also recall-tested) is the milder choice for a
  rig that is only slightly CPU-bound.
- **When to use it.** When the CPU, not the GPUs, limits the rig: a 2-core
  host with more than about 4 RTX 4080-class GPUs at full clock, or more than
  about 2 with slow cores; in general when the miners' total graph rate
  approaches `1.6 × 1000 / 30` ≈ 55 graphs/s per 2 fast cores at ntrims 50.
  Symptoms: CPU near 100% while mining, and per-GPU graph rates clearly below
  what the same card makes in a desktop.
- **Follow-ups.** Measure on a real weak host (2a) or with the CPU capped, to
  replace the half-speed estimate; recall-test 64 if very CPU-bound rigs need
  it; repeat the GPU-cost measurement on sm_86 and sm_120 (the CPU-side saving
  is a property of the graph and should carry over, the GPU cost per round may
  not).
