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
findcycles ms  : p50=3.120 p99=4.870 max=9.410  (main thread, per graph)
cpu busy       : fraction=0.0421  (findcycles 6.170 s / wall 146.530 s)
lost edges     : oops_graphs=0 node_overflow_graphs=0
```

- **surviving edges**: edges left after trimming, per graph, before the copy
  to the host is capped at `MAXEDGES` (2^20). Every graph whose trim
  succeeded counts.
- **findcycles ms**: time the main thread spends in
  `findcycles_copied_status` (the cycle search, plus the GPU recovery step on
  the ~1 in 42 graphs with a cycle), per graph that had edges. It is wall time
  from a monotonic clock (`steady_clock`) on the calling thread, so it also
  counts time the thread waited for a core. That is what matters on a busy
  host.
- **cpu busy**: total `findcycles` time divided by the wall time of the run
  (the same time as the `graphs/s` line). It is the share of the main thread
  spent searching for cycles. With pipeline 2 or more the search overlaps
  other contexts' trims, so it is free as long as this stays well below 1.
- **lost edges**: graphs with more than `MAXEDGES` surviving edges (these
  also print `OOPS; losing ... edges beyond MAXEDGES`), and graphs whose cycle
  search printed at least one `NODE OVERFLOW`. Both lose solutions.

Percentiles use the nearest-rank method: p is the value at 1-based rank
ceil(p/100 × n) of the sorted values, so p50 of 2000 graphs is the 1000th
smallest and p99 the 1980th. The same values go into the `--recall-jsonl`
summary record as optional keys (`edges_min`, `edges_p50`, `edges_p99`,
`edges_max`, `findcycles_ms_p50`, `findcycles_ms_p99`, `findcycles_ms_max`,
`findcycles_sec`, `elapsed_sec`, `busy_fraction`, `oops_graphs`,
`node_overflow_graphs`). `tests/tari_c29_gpu_recall.py` accepts files with or
without them and does not use them in the proof comparison.

## What the sweep does

For each `ntrims` in 50, 48, 46, 44, 42, 40, 36, 32 (the current default is
always included), highest first:

1. A 60 s warm-up run at that `ntrims`.
2. Three back-to-back runs of `--count 2000 --ntrims N` with auto pipeline.
   The median `graphs/s` is the result.
3. The 2-core check: both processes pinned to cores 0 and 1 (affinity mask 3
   on Windows, `taskset -c 0,1` on Linux). A second solver runs on the same
   GPU with `--pipeline 1` to load the CPU the way a second GPU of a weak
   multi-GPU rig would, then one measured `--count 2000` run reports the busy
   fraction.
4. Stop going lower once any of these is true for this `ntrims`:
   - max surviving edges in any run > 524,288 (50% of `MAXEDGES`)
   - any `OOPS` or `NODE OVERFLOW` (`oops_graphs` or `node_overflow_graphs`
     above 0)
   - busy fraction in the 2-core check > 0.40

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
   `-AffinityMask 12` for other cores (a bit mask: 3 is cores 0 and 1).
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
| findcycles ms p99 (full / 2-core) | highest p99 of the measured runs / p99 of the 2-core run |
| busy (full / 2-core) | highest busy fraction of the measured runs / the 2-core run |
| result | `default`, `no gain`, `gain`, `**chosen**`, `stop: <reason>`, or `not run (stopped above)` |

The script ends with `chosen_ntrims=N` (or `chosen_ntrims=none` if nothing
beats the default; then keep it and report the table). Look at the table, not
only the choice:

- If the 2-core busy fraction is far above the full-host one, a weak host is
  what limits `ntrims`. Choosing `ntrims` at runtime from the CPU load is out
  of scope; note it as a follow-up in the PR.
- If the gains are small and close to 0.5%, re-run those values to make sure
  they hold.

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
