# Late trim rounds and worker threads: GPU validation

These steps measure and validate the experimental options added for cheaper late
trim rounds (spec 2) and the persistent trim worker threads (spec 5b). They are
written for a Windows machine with an RTX 40 card (`sm_89`), from an x64 Native
Tools Command Prompt in the repository root. Every option is off by default, so
a build without `TARI_ARCH_FLAGS` is the baseline.

| Macro | Default | What it does |
|-------|---------|--------------|
| `LATE_ROUND_SELF_ZERO_IDX=1` | 0 | Rounds 2, 3 and the late rounds zero the bucket counts they read; 48 of the 54 index memsets per graph go away (at 50 trims) |
| `TRIM_CUDA_GRAPH=1` | 0 | Per-context stream; Round 0 through the final count copy runs as one CUDA graph. **-17% on sm_89, see the warning in Step 2b** |
| `LATE_ROUND_BPB=2/4/8` | 1 | Late rounds use `RoundMulti`, with each block handling 2, 4 or 8 buckets (grid 16384 / BPB) |
| `ROUND_LATE_TPB=N` | 0 (use `trim.tpb`, 320) | Threads per block in the late rounds, existing option |

Each build overwrites `bin\tari_c29_solver_sm_89.exe`, so copy it to a named
file straight after building. Keep `TARI_ARCH_FLAGS` set to the build's flags
whenever you run `tests\tari_c29_gpu_recall.py`, because it reads the
expected trim count from them.

## Benchmark method

Use the same method as `build_flags/sm_89.flags`: `--count 2000 --nonce 0`,
one warm-up run, then 5 measured runs; take the median graphs/s. Keep a
change only if its gain is above 0.5% and above the spread of the baseline
runs. Keep the GPU, clocks, power limit and pipeline depth the same for every
run, and write them down.

```bat
for /L %i in (0,1,5) do bin\candidates\NAME.exe --count 2000 --nonce 0 | findstr "graphs solved"
```

## Step 0: where the trim time goes

1. Build with stage timing and keep the binary:

   ```bat
   set "TARI_ARCH_FLAGS=-DTRIM_STAGE_TIMING=1"
   build_solver.bat sm_89
   mkdir bin\candidates
   copy bin\tari_c29_solver_sm_89.exe bin\candidates\timing.exe
   ```

2. Run it with one context; the event syncs serialize the stages, so pipeline
   overlap would only distort the numbers:

   ```bat
   bin\candidates\timing.exe --count 200 --pipeline 1 > timing.log
   ```

3. Average each `stage-ms` field, skipping the first 10 graphs:

   ```powershell
   $rows = Select-String -Path timing.log -Pattern '^stage-ms SeedA' | Select-Object -Skip 10 |
     ForEach-Object { $f = $_.Line -split ' '; [pscustomobject]@{
       SeedA=[double]$f[2]; SeedB=[double]$f[4]; R0=[double]$f[6]; R1=[double]$f[8]
       R2=[double]$f[10]; R3=[double]$f[12]; Late=[double]$f[14]; Tail=[double]$f[16] } }
   $avg = $rows | Measure-Object SeedA,SeedB,R0,R1,R2,R3,Late,Tail -Average
   $avg | Format-Table Property,Average
   $total = ($avg | Measure-Object Average -Sum).Sum
   'late share: {0:P1}' -f (($avg | Where-Object Property -eq 'Late').Average / $total)
   ```

4. Count kernels and memsets per graph with Nsight Systems (optional; the
   expected numbers at 50 trims with the default build are 57 kernel launches:
   SeedA 1, SeedB 4, Round 0 2, Rounds 1-3 3, late 46, Tail 1; and 54 index
   memsets: 7 before the late loop, 46 inside it, 1 before Tail):

   ```bat
   nsys profile -o step0 --stats=true bin\candidates\timing.exe --count 20 --pipeline 1
   ```

   Divide the `cuda_gpu_kern_sum` and `cuda_gpu_mem_size_sum` / memset
   instance counts by 20.

**Decision:** if the late rounds are under 10% of the trim time, keep only 2a
(if it gains) and stop. Otherwise go on with 2b and 2c.

## Step 2a: self-zeroing counts

```bat
set "TARI_ARCH_FLAGS= "
build_solver.bat sm_89
copy bin\tari_c29_solver_sm_89.exe bin\candidates\baseline.exe
set "TARI_ARCH_FLAGS=-DLATE_ROUND_SELF_ZERO_IDX=1"
build_solver.bat sm_89
copy bin\tari_c29_solver_sm_89.exe bin\candidates\2a.exe
```

Benchmark `baseline.exe` and `2a.exe` as above.

## Step 2b: CUDA graph

> **Warning: 2b measured -17% on sm_89.** On an RTX 4080 (2026-10-06, CUDA 13.4,
> auto pipeline 2) `-DTRIM_CUDA_GRAPH=1` dropped throughput from 13.793 to
> 11.446 g/s, and 2a + 2b to 11.354 g/s
> ([results](sm89_results_2026-10-06.md)). The expected effect was a gain under
> 1%, so a loss this large points at a structural cost rather than noise. The
> likely cause is the per-context non-blocking stream the graph needs, which
> changes how the pipeline contexts' trims overlap; this has not been profiled.
> **Do not enable `TRIM_CUDA_GRAPH` on any arch** unless it is benchmarked on that
> arch first and beats the baseline by the keep rule, and treat a gain on one
> arch as no evidence for another.

```bat
set "TARI_ARCH_FLAGS=-DTRIM_CUDA_GRAPH=1"
build_solver.bat sm_89
copy bin\tari_c29_solver_sm_89.exe bin\candidates\2b.exe
set "TARI_ARCH_FLAGS=-DLATE_ROUND_SELF_ZERO_IDX=1 -DTRIM_CUDA_GRAPH=1"
build_solver.bat sm_89
copy bin\tari_c29_solver_sm_89.exe bin\candidates\2a_2b.exe
```

The expected gain is under about 1%. **Keep 2b only if it beats the baseline
(and `2a_2b` beats `2a`) by the keep rule.** With `-DTRIM_STAGE_TIMING=1` added,
a graph build prints `stage-ms SeedA .. SeedB .. graph(R0..tail) ..`: Round 0
through the count copy is timed as one stage, because per-round event syncs
cannot be captured into a graph.

## Step 2c: buckets per block

Sweep `LATE_ROUND_BPB` 2, 4, 8 against `ROUND_LATE_TPB` 256, 512, 1024. Put
the 2a flag (and the 2b flag, if 2b was kept) in `BASE`:

```bat
set "BASE=-DLATE_ROUND_SELF_ZERO_IDX=1"
for %b in (2 4 8) do for %t in (256 512 1024) do (
  set "TARI_ARCH_FLAGS=%BASE% -DLATE_ROUND_BPB=%b -DROUND_LATE_TPB=%t"
  call build_solver.bat sm_89
  copy bin\tari_c29_solver_sm_89.exe bin\candidates\2c_bpb%b_tpb%t.exe
)
```

Inside a `.bat` file, double the percent signs (`%%b`, `%%t`) and use
`setlocal enabledelayedexpansion` with `!BASE!`. Also benchmark
`BASE` with `ROUND_LATE_TPB` 256, 512 and 1024 alone (no `LATE_ROUND_BPB`), so
the BPB effect is separate from the block-size effect. `LATE_ROUND_BPB=8` needs
64 KB of shared memory per block, so it only fits one block per SM.

## Recall parity (every candidate that is kept)

Build the reference once, then run the full recall sequence for each kept
candidate, with `TARI_ARCH_FLAGS` set to the flags that candidate was built
with:

```bat
build_solver.bat sm_89 reference
set "TARI_ARCH_FLAGS=<candidate flags>"
python tests\tari_c29_gpu_recall.py run --candidate bin\candidates\NAME.exe --reference bin\validation\tari_c29_solver_sm_89_reference.exe --arch sm_89 --output-dir validation --parity-pipeline 4
```

It must print a passing report: candidate and reference proof sets identical,
and pipeline 4 identical to pipeline 1.

Also run it for the final combination built with `-DFUSE_FINAL_TAIL_CURRENT=1`
added, because the fused tail reads the last late round's output and changes
which index buffer holds the final count.

**Small trim counts.** `ntrims` 2 and 4 run no late rounds at all, which is
the edge case for 2a (Round 3's output goes straight to `Tail` or, with the
fused tail, straight to the count copy). They leave far more than `MAXEDGES`
edges, so the recall runner rejects them as "edge truncation" whatever the
build, and their proof sets are not repeatable. Smoke-test them instead; each
run must exit 0 and print `verify failures: 0` with no `fatal` line:

```bat
for %n in (2 4 6) do bin\candidates\NAME.exe --count 20 --ntrims %n --pipeline 2
```

Then find the smallest trim count with no `OOPS; losing` line in a reference
run (`bin\validation\tari_c29_solver_sm_89_reference.exe --count 20 --ntrims N`),
and run the recall sequence at that count on both sides:

```bat
python tests\tari_c29_gpu_recall.py run --candidate bin\candidates\NAME.exe --reference bin\validation\tari_c29_solver_sm_89_reference.exe --arch sm_89 --output-dir validation --parity-pipeline 4 --candidate-ntrims N --reference-ntrims N
```

## Spec 5b smoke runs: persistent worker threads

Build the default release solver and pool miner (no `TARI_ARCH_FLAGS`), then
run each for about 2 minutes with 3 pipeline contexts:

```bat
set "TARI_ARCH_FLAGS="
build_solver.bat sm_89
build_pool_miner.bat sm_89
bin\tari_c29_solver_sm_89.exe --count 1700 --pipeline 3
bin\tari_c29_pool_miner_sm_89.exe --pool taric29-ca.luckypool.io:3111 --wallet YOUR_TARI_WALLET --worker smoke --pipeline 3 --max-runtime-sec 120
```

Pass criteria:

- The solver ends with `verify failures: 0` and exit code 0; graphs/s is no
  lower than a build from before this change at the same pipeline depth.
- The pool miner runs the full 120 s, reports speed, and exits 0.
- The thread count stays flat while it runs (with `std::async` it varied).
  In another PowerShell window:

  ```powershell
  1..12 | ForEach-Object { (Get-Process tari_c29_pool_miner_sm_89).Threads.Count; Start-Sleep 10 }
  ```

## After measuring

Record the numbers and the decision in `build_flags/sm_89.flags`, in the same
format as the existing sweep, and add the winning flags there. Options that do
not pass the keep rule stay off.
