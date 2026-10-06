# Checkpointed SeedA: spill report and GPU validation

`SEEDA_CHECKPOINT=C` (C = 8, 16 or 32; default 0 = off) is a third way for
`SeedA` to produce the 64 edges of a sipblock. Every edge needs the block's
last hash `h_63`. The kernel keeps the first C hashes in registers, saves the
SipHash state after them, runs on to `h_63`, then restarts from the saved
state for the remaining edges. The schedule is `seedaCheckpointBlock()` in
`seeda_checkpoint.h`; `tests/tari_seeda_schedule_test.cpp` runs that same
template on the host and checks it against the other two modes and the
reference `tari_c29_edge()`.

| Mode | Hashes per block | Local memory | Notes |
|------|------------------|--------------|-------|
| `SEEDA_REHASH=0` (reference) | 64 | 512 B `buf[64]` | `dipblock()` |
| `SEEDA_REHASH=1` (release default) | 127 | 0 | |
| `SEEDA_CHECKPOINT=8` | 119 | 0 | |
| `SEEDA_CHECKPOINT=16` | 111 | 0 | |
| `SEEDA_CHECKPOINT=32` | 95 | spills on sm_86 / sm_89 | |

A non-zero `SEEDA_CHECKPOINT` overrides `SEEDA_REHASH`; any value other than
0, 8, 16 or 32 is a compile error. With the default 0 the `SeedA` SASS of
every build (solver and pool miner, `SEEDA_REHASH` 0 and 1, sm_86 / sm_89 /
sm_120) is byte-for-byte the same as before the change.

## Spill report

`-maxrregcount=96`, CUDA 12.8.0 (`nvidia/cuda:12.8.0-devel-ubuntu22.04`),
release profile plus `build_flags/<arch>.flags`, `SeedA` only. The pool miner
gives the same numbers in every row.

| Arch | Mode | Registers | Spill stores (B) | Spill loads (B) | Stack frame (B) | SASS instructions |
|------|------|-----------|------------------|-----------------|-----------------|-------------------|
| sm_86 | `SEEDA_REHASH=0` | 85 | 0 | 0 | 512 | 952 |
| sm_86 | `SEEDA_REHASH=1` | 91 | 0 | 0 | 0 | 976 |
| sm_86 | `SEEDA_CHECKPOINT=8` | 96 | 0 | 0 | 0 | 1,664 |
| sm_86 | `SEEDA_CHECKPOINT=16` | 93 | 0 | 0 | 0 | 1,696 |
| sm_86 | `SEEDA_CHECKPOINT=32` | 96 | 12 | 24 | 16 | 1,880 |
| sm_89 | `SEEDA_REHASH=0` | 85 | 0 | 0 | 512 | 952 |
| sm_89 | `SEEDA_REHASH=1` | 91 | 0 | 0 | 0 | 976 |
| sm_89 | `SEEDA_CHECKPOINT=8` | 96 | 0 | 0 | 0 | 1,664 |
| sm_89 | `SEEDA_CHECKPOINT=16` | 93 | 0 | 0 | 0 | 1,696 |
| sm_89 | `SEEDA_CHECKPOINT=32` | 96 | 12 | 24 | 16 | 1,880 |
| sm_120 | `SEEDA_REHASH=0` | 64 | 0 | 0 | 512 | 944 |
| sm_120 | `SEEDA_REHASH=1` | 72 | 0 | 0 | 0 | 808 |
| sm_120 | `SEEDA_CHECKPOINT=8` | 87 | 0 | 0 | 0 | 984 |
| sm_120 | `SEEDA_CHECKPOINT=16` | 96 | 0 | 0 | 0 | 1,000 |
| sm_120 | `SEEDA_CHECKPOINT=32` | 95 | 0 | 0 | 0 | 1,072 |

The `SEEDA_REHASH=0` stack frame is the `buf[64]` array in local memory, not a
spill.

**Candidates (no spills):** sm_86 and sm_89: C = 8 and 16. sm_120: C = 8, 16
and 32. C = 32 is not a candidate on sm_86 / sm_89.

**Code size.** `buf` only stays in registers if every index into it is a
compile-time constant. The first version did that by fully unrolling the two
`buf` loops, which copied `hash24` and the whole emit body (two barriers,
atomics and the flush, about 640 instructions) C times. That gave 6,616 /
11,776 / 22,208 SASS instructions on sm_89 for C = 8 / 16 / 32 (about 105 /
188 / 355 KB), against 976 for rehash. That is more than the instruction
cache, and the fetch misses could cancel the hashes saved. Now all four loops
are rolled. The two `buf` loops append at `buf[C - 1]` or emit `buf[0]`, and
then shift `buf` down by one with an unrolled copy. That costs about C*C
register moves per block but keeps one copy of each body: SeedA now has two
emit sites (five `BAR.SYNC`, including the counter reset), and each thread
still runs 64 emits and 128 barriers per block. The spills are the same as in
the unrolled version, except for C = 32 on sm_86 / sm_89, which spilled 8 B
each way and now spills 12 / 24 B. It was not a candidate in either version.

To reproduce (about 4 minutes on Apple silicon under emulation):

```bash
docker run --rm --platform linux/amd64 -v "$PWD":/src -w /src \
    nvidia/cuda:12.8.0-devel-ubuntu22.04 tools/seeda_spill_report.sh
```

Pass archs to limit the run (`tools/seeda_spill_report.sh sm_89`). Set
`SEEDA_SASS_DIR=<dir>` (as `-e SEEDA_SASS_DIR=/src/_sass` for Docker) to also
write each build's `SeedA` SASS, for example to diff it against another
commit. Register allocation depends on the CUDA version, so with another
toolkit (the RTX 4080 machine uses CUDA 13.x) check the spills of the build
you benchmark, as in step 1 below.

## GPU validation on the RTX 4080 (sm_89, Windows)

Run from an x64 Native Tools Command Prompt in the repository root.
`build_flags/sm_89.flags` is empty, so `TARI_ARCH_FLAGS` holds only the
candidate flag. Each build overwrites `bin\tari_c29_solver_sm_89.exe`, so copy
it to a named file straight after building.

1. **Build the candidates and check spills with the local toolkit.** The
   baseline is the release default (`SEEDA_REHASH=1`):

   ```bat
   mkdir bin\candidates
   set "TARI_ARCH_FLAGS= "
   build_solver.bat sm_89
   copy bin\tari_c29_solver_sm_89.exe bin\candidates\rehash.exe
   for %c in (8 16) do (
     set "TARI_ARCH_FLAGS=-DSEEDA_CHECKPOINT=%c -Xptxas -v"
     call build_solver.bat sm_89 > seeda_c%c_build.log 2>&1
     copy bin\tari_c29_solver_sm_89.exe bin\candidates\c%c.exe
   )
   ```

   Inside a `.bat` file, use `%%c` and `setlocal enabledelayedexpansion`.
   `-Xptxas -v` only adds compiler output. Check that `SeedA` has
   `0 bytes spill stores, 0 bytes spill loads` and a `0 bytes stack frame`:

   ```powershell
   foreach ($c in 8, 16) { Select-String -Path "seeda_c${c}_build.log" -Pattern "Compiling entry function '_Z5SeedA" -Context 0,2 }
   ```

   A candidate that spills with this toolkit is out.

2. **SeedA stage time.** Build each candidate again with stage timing (these
   binaries are for the breakdown only, never for g/s):

   ```bat
   set "TARI_ARCH_FLAGS=-DTRIM_STAGE_TIMING=1"
   build_solver.bat sm_89
   copy bin\tari_c29_solver_sm_89.exe bin\candidates\timing_rehash.exe
   set "TARI_ARCH_FLAGS=-DTRIM_STAGE_TIMING=1 -DSEEDA_CHECKPOINT=8"
   build_solver.bat sm_89
   copy bin\tari_c29_solver_sm_89.exe bin\candidates\timing_c8.exe
   set "TARI_ARCH_FLAGS=-DTRIM_STAGE_TIMING=1 -DSEEDA_CHECKPOINT=16"
   build_solver.bat sm_89
   copy bin\tari_c29_solver_sm_89.exe bin\candidates\timing_c16.exe
   for %n in (rehash c8 c16) do bin\candidates\timing_%n.exe --count 200 --pipeline 1 > timing_%n.log
   ```

   Average the `SeedA` field, skipping the first 10 graphs:

   ```powershell
   foreach ($n in 'rehash', 'c8', 'c16') {
     $ms = Select-String -Path "timing_$n.log" -Pattern '^stage-ms SeedA' | Select-Object -Skip 10 |
       ForEach-Object { [double](($_.Line -split ' ')[2]) }
     '{0,-7} SeedA {1:N3} ms' -f $n, ($ms | Measure-Object -Average).Average
   }
   ```

3. **Throughput.** Follow the benchmark protocol: 1 minute of warm-up, then 3
   runs back to back, median of the `graphs/s` summary line. Do this for
   `rehash.exe` and each candidate that cut SeedA time, without changing
   clocks or power limit in between:

   ```bat
   bin\candidates\rehash.exe --count 800 > nul
   for /L %i in (1,1,3) do bin\candidates\rehash.exe --count 2000 | findstr "graphs/s"
   for /L %i in (1,1,3) do bin\candidates\c16.exe --count 2000 | findstr "graphs/s"
   ```

   Repeat the warm-up before each candidate if the runs are far apart. A
   candidate wins only if its median beats the rehash median by at least 0.5%
   and every one of its runs beats the rehash median. Record GPU, driver and
   CUDA version.

4. **Recall parity** for the winner (the reference build is unchanged and
   keeps `SEEDA_REHASH=0`). Keep `TARI_ARCH_FLAGS` set to the winner's flags:

   ```bat
   build_solver.bat sm_89 reference
   set "TARI_ARCH_FLAGS=-DSEEDA_CHECKPOINT=16"
   python tests\tari_c29_gpu_recall.py run --candidate bin\candidates\c16.exe --reference bin\validation\tari_c29_solver_sm_89_reference.exe --arch sm_89 --output-dir validation --parity-pipeline 2
   ```

   The proof sets must be identical.

5. **Enable the winner.** Add the flag as its own line in
   `build_flags/sm_89.flags`, with the measurements in the comment block in
   the same format as the existing sweep (SeedA ms per mode, the three g/s
   runs and the median for rehash and each candidate):

   ```
   -DSEEDA_CHECKPOINT=16
   ```

   Then rebuild with `TARI_ARCH_FLAGS` unset (`set "TARI_ARCH_FLAGS="`) and
   check that the build prints the flag. If no candidate passes, leave the
   file as it is.

**Other archs.** sm_86 is the same, with `sm_86` in place of `sm_89`.
`build_flags/sm_120.flags` is not empty and `TARI_ARCH_FLAGS` replaces it, so
on sm_120 put the whole list from that file in `TARI_ARCH_FLAGS` together with
`-DSEEDA_CHECKPOINT=C`, also for the baseline, and include C = 32.
