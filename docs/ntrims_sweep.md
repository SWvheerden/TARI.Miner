# Trim-round count (ntrims) sweep

The GPU runs `ntrims` trim rounds per graph (50 by default, 48 on `sm_120`),
then the host searches the surviving edges for 42-cycles. Fewer rounds save
GPU time but leave more edges, and so more work, for the host. This sweep
finds the lowest `ntrims` per arch that is faster on the GPU while staying
inside the edge and CPU limits. Trimming only removes edges that cannot be on a
cycle, so stopping earlier never loses a solution, as long as no edges are
dropped (`OOPS`) and the compressor does not overflow (`NODE OVERFLOW`).

These steps are written for a Windows machine with an RTX 4080 (`sm_89`), from
an x64 Native Tools Command Prompt in the repository root. The Linux steps are
the same with `./build_solver.sh` and `tools/ntrims_sweep.sh`.

## What the solver reports

`tari_c29_solver` prints these lines at the end of the `--- summary ---`
block, after the existing ones:

```text
surviving edges: min=88123 p50=101234 p99=118000 max=121456  (per graph, before the MAXEDGES=1048576 cap)
cycle search ms: p50=3.020 p99=4.410 max=5.120 mean=3.0811  (host graph build + cycle finding per graph, main-thread wall time, without GPU recovery; mean over all graphs)
cpu busy       : fraction=0.0421  (cycle search 6.162 s / wall 146.530 s)
gpu recovery   : graphs=47 total=0.390 s  (proof recovery for graphs with a cycle)
lost edges     : oops_graphs=0 node_overflow_graphs=0
```

- **surviving edges**: edges left after trimming, per graph, before the copy
  to the host is capped at `MAXEDGES` (2^20). Every graph whose trim
  succeeded counts.
- **cycle search ms**: the host part of `findcycles_copied_status` per graph
  that had edges: the graph reset, adding the edges and finding cycles. It
  does not include the GPU recovery of a cycle found (about 1 graph in 42),
  which is GPU queueing rather than CPU cost and is reported on its own line.
  It is wall time from a monotonic clock (`steady_clock`) on the main thread,
  so it also counts time the thread waited for a core, which is what matters
  on a busy host. `mean` is the total over all graphs of the run, searched or
  not, so `mean / 1000 × graphs/s` is the busy fraction.
- **cpu busy**: total cycle-search time divided by the wall time of the run
  (the same time as the `graphs/s` line). It is the share of the main thread
  spent searching for cycles. With pipeline 2 or more the search overlaps
  other contexts' trims, so it is free as long as this stays well below 1.
- **gpu recovery**: graphs that found a cycle and ran the GPU recovery, and
  the main thread's total time in it.
- **lost edges**: graphs with more than `MAXEDGES` surviving edges (these
  also print `OOPS; losing ... edges beyond MAXEDGES`), and graphs whose cycle
  search printed at least one `NODE OVERFLOW`. Both lose solutions.

Percentiles use the nearest-rank method: p is the value at 1-based rank
ceil(p/100 × n) of the sorted values, so p50 of 2000 graphs is the 1000th
smallest and p99 the 1980th. The same values go into the `--recall-jsonl`
summary record as optional keys (`edges_min`, `edges_p50`, `edges_p99`,
`edges_max`, `search_ms_p50`, `search_ms_p99`, `search_ms_max`,
`search_ms_mean`, `search_sec`, `recovery_graphs`, `recovery_sec`,
`elapsed_sec`, `busy_fraction`, `oops_graphs`, `node_overflow_graphs`). `tests/tari_c29_gpu_recall.py` accepts files with or
without them and does not use them in the proof comparison.

## What the sweep does

For each `ntrims` in 50, 48, 46, 44, 42, 40, 36, 32 (the current default is
always included), highest first:

1. A 60 s warm-up run at that `ntrims`.
2. Three back-to-back runs of `--count 2000 --ntrims N` with auto pipeline.
   The median `graphs/s` is the result.
3. The 2-core check: both processes pinned to the same two physical cores.
   A second solver runs on the same GPU with `--pipeline 1` to load the CPU
   the way a second GPU of a weak multi-GPU rig would, then one measured
   `--count 2000` run measures the cycle-search cost on the crowded CPU.
4. Stop going lower once any of these is true for this `ntrims`:
   - max surviving edges in any run > 524,288 (50% of `MAXEDGES`)
   - any `OOPS` or `NODE OVERFLOW` (`oops_graphs` or `node_overflow_graphs`
     above 0)
   - projected busy fraction in the 2-core check > 0.40

**Projected busy fraction.** In the 2-core run the measured process shares
its GPU with the second solver, so it makes fewer graphs per second (and auto
pipeline may pick fewer contexts) while each graph's search costs the same.
Its measured busy fraction is then too low, about half of what a real rig
with one GPU per process would show. The stop rule therefore uses the 2-core
run's search time per graph (`mean`) times the full-GPU median graphs/s for
that `ntrims`, capped at 1. The table and CSV show both the measured and the
projected fraction, and the pipeline depth the 2-core run used. With
`-LoadDevice` / `--load-device` on a second GPU the measured fraction is
valid as well; the stop rule still uses the projection so every sweep is
judged the same way.

**Which CPUs.** Two logical CPUs on one physical core (SMT siblings) would
test one core, not two. On Windows, which numbers SMT siblings next to each
other, the script uses affinity mask 5 (logical CPUs 0 and 2) when the CPU
has SMT and 3 otherwise. On Linux it reads
`/sys/devices/system/cpu/cpu*/topology` and takes the first two CPUs on
different cores (often `0,1` on Linux, which numbers the siblings last),
falling back to `0,1`. `-AffinityMask` and `--cpus` override this. `sweep.md`
records the CPUs used and why.

Then it picks the lowest `ntrims` that did not stop and whose median beats the
current default's median by at least 0.5%, with every one of its runs above
that median (the benchmark rule in the spec index).

The current default is read the same way as the recall harness reads it:
`TARI_ARCH_FLAGS` if set and non-empty, otherwise `build_flags/<arch>.flags`,
otherwise 50. Leave `TARI_ARCH_FLAGS` unset unless the solver was built with it.

## Steps on the RTX 4080

1. Build the release and the reference solver. Make sure `TARI_ARCH_FLAGS` is
   not set, so the release build uses `build_flags\sm_89.flags`:

   ```bat
   set TARI_ARCH_FLAGS=
   build_solver.bat sm_89
   build_solver.bat sm_89 reference
   ```

2. Check that the solver prints the new lines:

   ```bat
   bin\tari_c29_solver_sm_89.exe --count 100
   ```

3. Prepare the machine: close games, browsers with video, other miners and
   anything else that uses the GPU or a lot of CPU. Do not change clocks or
   power limits during the sweep.

4. Run the sweep (about 10 to 12 minutes per `ntrims`, so up to 1.5 hours):

   ```bat
   powershell -ExecutionPolicy Bypass -File tools\ntrims_sweep.ps1 -Arch sm_89
   ```

   Useful options: `-Ntrims 50,46,42` to try fewer values, `-LoadDevice 1`
   to put the second process of the 2-core check on a second GPU, and
   `-AffinityMask N` to choose the logical CPUs yourself (a bit mask: 5 is
   logical CPUs 0 and 2).
   `-DryRun` runs the whole script against a fake solver in a few seconds
   per value, which is a quick way to check the setup.

   On Linux: `tools/ntrims_sweep.sh --arch sm_86` (needs `taskset`, from
   util-linux). `--help` lists the options.

## Reading the results

Everything goes in `ntrims-sweep\sm_89-<time>\`:

- `sweep.md`: the GPU, driver and CUDA version, the settings, and the table
  for the PR.
- `sweep.csv`: one line per run (`full` for the three measured runs, `2core`
  for the 2-core check) with every number the solver printed.
- `ntrims-N-run1.log` and so on: the full solver output of each run.

Table columns:

| Column | Meaning |
|--------|---------|
| g/s median, g/s runs | median and each of the measured runs |
| vs default | median against the current default's median |
| edges p99, edges max | highest p99 and max over all runs at this `ntrims` |
| search ms p99 (full / 2-core) | highest cycle-search p99 of the measured runs / p99 of the 2-core run |
| busy full | highest measured busy fraction of the full-host runs |
| busy 2-core (measured / projected) | the 2-core run's measured fraction / the projection the stop rule uses |
| 2-core pipeline | pipeline depth the measured 2-core run used |
| result | `default`, `no gain`, `gain`, `**chosen**`, `stop: <reason>`, or `not run (stopped above)` |

The script ends with `chosen_ntrims=N` (or `chosen_ntrims=none` if nothing
beats the default; then keep it and report the table). Look at the table, not
only the choice:

- If the 2-core projected busy fraction is far above the full-host one, a weak host is
  what limits `ntrims`. Choosing `ntrims` at runtime from the CPU load is out
  of scope; note it as a follow-up in the PR.
- If the gains are small and close to 0.5%, re-run those values to make sure
  they hold.

## Measured: sm_89 at the default 50 trims (2026-10-06)

The first real sweep, on an RTX 4080 with `-DSEEDA_CHECKPOINT=32`
([full results](sm89_results_2026-10-06.md)), stopped at the default before
trying anything lower. What it found changes the premise of this sweep.

| | value | limit |
|---|---|---|
| surviving edges p99 / max per graph | 791,462 / 803,598 | stop rule 524,288 (50% of `MAXEDGES`) |
| max as a share of `MAXEDGES` (1,048,576) | 76.6% | edges above 100% are dropped |
| OOPS / NODE OVERFLOW graphs | 0 (the stop reason would list them) | any is a stop |
| busy fraction, full host (i5-13600KF) | 41.8% | |
| 2-core projected busy | 40.2% | stop rule 40% |

- **Far more edges survive 50 trims than the spec assumed.** Spec 3 expected
  tens of thousands; it is about 790k. Running fewer trims would push edge counts
  even closer to `MAXEDGES`, so on this design lower `ntrims` is not an option,
  whatever the g/s gain.
- **The headroom above the edge cap is about 23%, and recall can't see it.**
  Edges beyond `MAXEDGES` are dropped (`OOPS; losing ... edges`), losing any
  cycle through them. The recall comparison can't catch that, because the
  reference build runs the same 50 trims and would drop the same edges. Check
  `lost edges: oops_graphs=0 node_overflow_graphs=0` in the solver summary
  instead; this run had none.
- **The host CPU is already a large part of the cost.** A busy fraction of 42%
  on a fast desktop CPU, and a projected 40% on 2 cores, means a weak
  multi-GPU host (2 cores, 6 to 12 GPUs) is likely CPU-bound at 50 trims. That
  is also why the spec 5a sparse reset only saved about 3% per graph: the
  compressors are mostly full anyway.
- **Follow-up:** test `ntrims` above 50 (52, 54, 56). More trims cost GPU time
  but cut surviving edges, which widens the `MAXEDGES` margin and lowers CPU
  load. That trade may win on weak hosts even if it loses on a desktop. This
  script only sweeps downward. Running that test on a real weak host, rather
  than the 2-core projection, would settle it.

## Recall comparison

The script prints the command. Run it with the current binary and the chosen
value first; the reference stays at 50, and the proof sets must still match:

```bat
python tests\tari_c29_gpu_recall.py run --candidate bin\tari_c29_solver_sm_89.exe ^
    --reference bin\validation\tari_c29_solver_sm_89_reference.exe ^
    --arch sm_89 --output-dir validation --parity-pipeline 2 --candidate-ntrims N
```

It must print `PASS`. Any `OOPS` or `NODE OVERFLOW` in a log fails it.

## Shipping the new default (spec 3 part C)

1. In `build_flags\sm_89.flags` add (or change) the line

   ```text
   -DTARI_C29_DEFAULT_NTRIMS=N
   ```

   and update the comment block above it with the date, GPU, driver, CUDA
   version and the sweep table. `release_compiled_ntrims()` in the recall
   harness reads this file, so no other file needs to change.

2. Rebuild and run the recall comparison again, now without
   `--candidate-ntrims`:

   ```bat
   build_solver.bat sm_89
   python tests\tari_c29_gpu_recall.py run --candidate bin\tari_c29_solver_sm_89.exe ^
       --reference bin\validation\tari_c29_solver_sm_89_reference.exe ^
       --arch sm_89 --output-dir validation --parity-pipeline 2
   ```

3. Update the README where it mentions trim counts (the build flags section).

4. In the PR, include `sweep.md` (table, GPU, driver, CUDA) and the recall
   `PASS` line, for each arch whose default changed.

## Tests

`tests/ntrims_sweep_test.sh` and `tests/ntrims_sweep_test.ps1` run both
scripts in dry-run mode against `tests/ntrims_sweep_fake_solver.py`, covering
each stop rule, the gain rule, reading the default, and the failure cases
(solver crash, missing statistics lines, second process exiting early). CI runs
the bash test on Linux and the PowerShell test on Windows.
