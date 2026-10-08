#!/usr/bin/env bash
# Trim-round count (ntrims) sweep for one GPU arch (spec 3 part B).
# Guide: docs/ntrims_sweep.md. tools/ntrims_sweep.ps1 is the Windows version
# of the same sweep; tests/ntrims_sweep_test.sh runs it with a fake solver.
set -euo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${PYTHON:-python3}"

EDGE_LIMIT=524288     # 50% of MAXEDGES (2^20)
BUSY_LIMIT=0.40       # main-thread busy fraction in the 2-core check
MIN_GAIN=0.005        # a gain needs +0.5% on the median and every run above the baseline
LONG_COUNT=1000000000 # --count for warm-up and load processes, which are stopped

usage() {
    cat <<'EOF'
usage: tools/ntrims_sweep.sh --arch sm_86|sm_89|sm_120 [options]

Runs the release solver at each ntrims (auto pipeline) and picks the lowest
ntrims within the limits that beats the current default by >= 0.5%.

options:
  --solver PATH        solver binary (default: bin/tari_c29_solver_<arch>)
  --out DIR            results directory (default: ntrims-sweep/<arch>-<time>)
  --ntrims "LIST"      even ntrims values (default: "50 48 46 44 42 40 36 32");
                       the current default is always added
  --count N            graphs per run (default: 2000)
  --runs N             measured runs per ntrims (default: 3)
  --warmup SEC         warm-up before each ntrims (default: 60; 0 in --dry-run)
  --device N           GPU for the measured runs (default: 0)
  --load-device N      GPU for the second process in the 2-core check
                       (default: --device; use another GPU if there is one)
  --load-pipeline N    --pipeline of that second process (default: 1)
  --cpus LIST          CPUs for the 2-core check, for taskset -c (default: the
                       first two CPUs on different physical cores, from
                       /sys/devices/system/cpu/cpu*/topology; else 0,1)
  --default-ntrims N   current default (default: read from build_flags/<arch>.flags
                       or TARI_ARCH_FLAGS, like tests/tari_c29_gpu_recall.py)
  --dry-run            use tests/ntrims_sweep_fake_solver.py instead of the GPU
EOF
}

die() {
    echo "ntrims_sweep: $*" >&2
    exit 1
}

arch=""
solver=""
out_dir=""
ntrims_list="50 48 46 44 42 40 36 32"
count=2000
runs=3
warmup=""
device=0
load_device=""
load_pipeline=1
cpus=""
default_ntrims=""
dry_run=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) dry_run=1; shift; continue ;;
        -h|--help) usage; exit 0 ;;
    esac
    [[ $# -ge 2 ]] || die "$1 needs a value (see --help)"
    case "$1" in
        --arch) arch="$2" ;;
        --solver) solver="$2" ;;
        --out) out_dir="$2" ;;
        --ntrims) ntrims_list="$2" ;;
        --count) count="$2" ;;
        --runs) runs="$2" ;;
        --warmup) warmup="$2" ;;
        --device) device="$2" ;;
        --load-device) load_device="$2" ;;
        --load-pipeline) load_pipeline="$2" ;;
        --cpus) cpus="$2" ;;
        --default-ntrims) default_ntrims="$2" ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
    shift 2
done

is_uint() { [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]; }

case "$arch" in
    sm_86|sm_89|sm_120) ;;
    *) die "--arch must be sm_86, sm_89 or sm_120" ;;
esac
if [[ -z "$warmup" ]]; then
    if [[ $dry_run -eq 1 ]]; then warmup=0; else warmup=60; fi
fi
for value in "$count" "$runs" "$warmup" "$device" "$load_pipeline"; do
    is_uint "$value" || die "not a whole number: $value"
done
[[ $count -ge 1 && $runs -ge 1 && $load_pipeline -ge 1 ]] || die "--count, --runs and --load-pipeline must be >= 1"
[[ -n "$load_device" ]] || load_device="$device"
is_uint "$load_device" || die "not a whole number: $load_device"

if [[ $dry_run -eq 1 ]]; then
    solver_cmd=("$PYTHON" "$ROOT/tests/ntrims_sweep_fake_solver.py")
    solver_label="fake solver (dry run)"
else
    [[ -n "$solver" ]] || solver="$ROOT/bin/tari_c29_solver_$arch"
    [[ -x "$solver" ]] || die "solver not found or not executable: $solver (build it with ./build_solver.sh $arch)"
    solver_cmd=("$solver")
    solver_label="$solver"
fi

if [[ -z "$default_ntrims" ]]; then
    default_ntrims="$("$PYTHON" -c 'import sys; sys.path.insert(0, sys.argv[1]); import tari_c29_gpu_recall as r; print(r.release_compiled_ntrims(sys.argv[2]))' "$ROOT/tests" "$arch")" \
        || die "could not read the default ntrims with $PYTHON"
fi
is_uint "$default_ntrims" || die "bad default ntrims: $default_ntrims"

# Even values, highest first, with the default included once.
read -r -a requested <<< "$ntrims_list"
for n in "${requested[@]}" "$default_ntrims"; do
    if ! is_uint "$n" || [[ $n -lt 2 || $((n % 2)) -ne 0 ]]; then
        die "ntrims must be even and >= 2: $n"
    fi
done
ntrims_values=()
while read -r n; do
    ntrims_values+=("$n")
done < <(printf '%s\n' "${requested[@]}" "$default_ntrims" | sort -rn | uniq)

# Two logical CPUs on different physical cores. SMT siblings share a core,
# so two of them would test one core, not two. TARI_SWEEP_CPU_SYSFS replaces
# /sys/devices/system/cpu for the tests.
pick_cpus() {
    local sysfs="${TARI_SWEEP_CPU_SYSFS:-/sys/devices/system/cpu}" dir n key first="" first_key=""
    local numbers=()
    for dir in "$sysfs"/cpu[0-9]*; do
        [[ -r "$dir/topology/core_id" ]] || continue
        numbers+=("${dir##*/cpu}")
    done
    while read -r n; do
        [[ -n "$n" ]] || continue
        key="$(cat "$sysfs/cpu$n/topology/physical_package_id" 2>/dev/null || echo 0):$(cat "$sysfs/cpu$n/topology/core_id")"
        if [[ -z "$first" ]]; then
            first="$n"
            first_key="$key"
        elif [[ "$key" != "$first_key" ]]; then
            echo "$first,$n"
            return
        fi
    done < <(printf '%s\n' ${numbers[@]+"${numbers[@]}"} | sort -n)
}

if [[ -n "$cpus" ]]; then
    cpus_source="from --cpus"
else
    cpus="$(pick_cpus)"
    cpus_source="two different physical cores"
    if [[ -z "$cpus" ]]; then
        cpus="0,1"
        cpus_source="CPU topology unknown, so these may share one core"
    fi
fi

# The 2-core check pins both solver processes with taskset.
pin=()
pin_label="pinned with taskset"
if command -v taskset >/dev/null 2>&1; then
    pin=(taskset -c "$cpus")
elif [[ $dry_run -eq 1 ]]; then
    pin_label="not pinned (dry run without taskset)"
else
    die "taskset not found (util-linux); it is needed for the 2-core check"
fi

[[ -n "$out_dir" ]] || out_dir="$ROOT/ntrims-sweep/$arch-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$out_dir"
csv="$out_dir/sweep.csv"
table="$out_dir/sweep.md"

bg_pid=""
cleanup() {
    if [[ -n "$bg_pid" ]]; then
        kill "$bg_pid" 2>/dev/null || true
        wait "$bg_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# start_long LOG [PIN...] -- ARGS...: start a solver that runs until stopped.
start_long() {
    local log="$1"
    shift
    local pin_args=()
    while [[ "$1" != "--" ]]; do pin_args+=("$1"); shift; done
    shift
    ${pin_args[@]+"${pin_args[@]}"} "${solver_cmd[@]}" --count "$LONG_COUNT" "$@" > "$log" 2>&1 &
    bg_pid=$!
}

stop_long() {
    local what="$1" log="$2"
    if ! kill -0 "$bg_pid" 2>/dev/null; then
        wait "$bg_pid" 2>/dev/null || true
        bg_pid=""
        die "$what exited early; see $log"
    fi
    kill "$bg_pid" 2>/dev/null || true
    wait "$bg_pid" 2>/dev/null || true
    bg_pid=""
}

# run_measured LOG [PIN...] -- ARGS...
run_measured() {
    local log="$1"
    shift
    local pin_args=()
    while [[ "$1" != "--" ]]; do pin_args+=("$1"); shift; done
    shift
    if ! ${pin_args[@]+"${pin_args[@]}"} "${solver_cmd[@]}" --count "$count" "$@" > "$log" 2>&1; then
        die "solver run failed; see $log"
    fi
}

# Prints: gps edges_min p50 p99 max ms_p50 ms_p99 ms_max ms_mean busy oops overflow pipeline
parse_log() {
    awk '
        function num(v) { return v ~ /^[0-9]+(\.[0-9]+)?$/ }
        /^graphs solved / {
            for (i = 2; i <= NF; i++) if ($i == "graphs/s") gps = $(i - 1)
        }
        /^surviving edges:/ { p = "e_" }
        /^solver pipeline=/ { split($2, kv, "="); pipeline = kv[2] }
        /^cycle search ms:/ { p = "m_" }
        /^cpu busy / { p = "b_" }
        /^lost edges / { p = "l_" }
        /^(surviving edges:|cycle search ms:|cpu busy |lost edges )/ {
            for (i = 1; i <= NF; i++)
                if (split($i, kv, "=") == 2) v[p kv[1]] = kv[2]
        }
        END {
            split("e_min e_p50 e_p99 e_max m_p50 m_p99 m_max m_mean b_fraction l_oops_graphs l_node_overflow_graphs", keys, " ")
            line = gps
            if (!num(gps)) exit 1
            for (k = 1; k <= 11; k++) {
                if (!num(v[keys[k]])) exit 1
                line = line " " v[keys[k]]
            }
            # Without a "solver pipeline=" line the solver ran one context.
            if (pipeline == "") pipeline = 1
            print line " " pipeline
        }
    ' "$1" || die "cannot read the summary in $1 (is the solver built with the ntrims statistics?)"
}

calc() { awk "BEGIN { $1 }"; }
max_of() { printf '%s\n' "$@" | sort -g | tail -n 1; }
median_of() {
    printf '%s\n' "$@" | sort -g | awk '{ a[NR] = $1 }
        END { if (NR % 2) printf "%.3f", a[(NR + 1) / 2]; else printf "%.3f", (a[NR / 2] + a[NR / 2 + 1]) / 2 }'
}

# System details for the PR.
gpu_name="unknown"
driver="unknown"
cuda="unknown"
# The toolkit (nvcc) version is what the binaries were built with, so report
# it first. The driver's CUDA version is extra; newer drivers word the
# nvidia-smi header differently, so match any "CUDA ... Version: X".
driver_cuda=""
toolkit_cuda=""
if [[ $dry_run -eq 0 ]] && command -v nvidia-smi >/dev/null 2>&1; then
    driver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader -i "$device" 2>/dev/null | head -n 1)" || driver="unknown"
    [[ -n "$driver" ]] || driver="unknown"
    driver_cuda="$(nvidia-smi 2>/dev/null | sed -n 's/.*CUDA[A-Za-z ]*Version: *\([0-9.][0-9.]*\).*/\1/p' | head -n 1)" || driver_cuda=""
fi
if [[ $dry_run -eq 0 ]] && command -v nvcc >/dev/null 2>&1; then
    toolkit_cuda="$(nvcc --version | sed -n 's/.*release \([0-9.][0-9.]*\).*/\1/p' | head -n 1)" || toolkit_cuda=""
fi
if [[ -n "$toolkit_cuda" && -n "$driver_cuda" ]]; then
    cuda="$toolkit_cuda (nvcc; driver supports $driver_cuda)"
elif [[ -n "$toolkit_cuda" ]]; then
    cuda="$toolkit_cuda (nvcc)"
elif [[ -n "$driver_cuda" ]]; then
    cuda="$driver_cuda (driver; nvcc not found)"
fi

echo "arch,ntrims,kind,run,pipeline,graphs_per_sec,edges_min,edges_p50,edges_p99,edges_max,search_ms_p50,search_ms_p99,search_ms_max,search_ms_mean,busy_fraction,projected_busy,oops_graphs,node_overflow_graphs,log" > "$csv"

# Per ntrims (same index as ntrims_values).
measured=()
gps_runs=()
gps_median=()
edges_p99=()
edges_max=()
ms_p99_full=()
ms_p99_weak=()
busy_full=()
busy_weak=()
busy_projected=()
pipeline_weak=()
stop_reason=()

stopped=0
for i in "${!ntrims_values[@]}"; do
    n="${ntrims_values[$i]}"
    measured[i]=0
    stop_reason[i]=""
    [[ $stopped -eq 0 ]] || continue
    echo "=== ntrims $n ==="

    if [[ $warmup -gt 0 ]]; then
        echo "warm-up ${warmup} s"
        start_long "$out_dir/ntrims-$n-warmup.log" -- --device "$device" --ntrims "$n"
        sleep "$warmup"
        stop_long "warm-up solver" "$out_dir/ntrims-$n-warmup.log"
    fi

    run_gps=()
    p99s=()
    maxes=()
    ms99s=()
    busys=()
    lost=0
    for ((r = 1; r <= runs; r++)); do
        log="$out_dir/ntrims-$n-run$r.log"
        run_measured "$log" -- --device "$device" --ntrims "$n"
        parsed="$(parse_log "$log")"
        read -r gps emin ep50 ep99 emax m50 m99 mmax mmean busy oops ovf pipe <<< "$parsed"
        echo "$arch,$n,full,$r,$pipe,$gps,$emin,$ep50,$ep99,$emax,$m50,$m99,$mmax,$mmean,$busy,,$oops,$ovf,$(basename "$log")" >> "$csv"
        echo "run $r: $gps g/s (pipeline $pipe), edges max $emax, search p99 $m99 ms, busy $busy"
        run_gps+=("$gps")
        p99s+=("$ep99")
        maxes+=("$emax")
        ms99s+=("$m99")
        busys+=("$busy")
        lost=$((lost + oops + ovf))
    done

    gps_median[i]="$(median_of "${run_gps[@]}")"

    # 2-core check: a second solver on the same cores, then one measured run.
    # Sharing one GPU with the second solver lowers this run's graph rate, so
    # its measured busy fraction is too low. The stop rule uses the projected
    # fraction instead: its search time per graph at the full-GPU median g/s.
    load_log="$out_dir/ntrims-$n-2core-load.log"
    log="$out_dir/ntrims-$n-2core.log"
    start_long "$load_log" ${pin[@]+"${pin[@]}"} -- --device "$load_device" --pipeline "$load_pipeline" --ntrims "$n"
    if [[ $dry_run -eq 0 ]]; then
        sleep 10 # let the second process allocate its GPU memory first
    fi
    run_measured "$log" ${pin[@]+"${pin[@]}"} -- --device "$device" --ntrims "$n"
    stop_long "2-core load solver" "$load_log"
    parsed="$(parse_log "$log")"
    read -r gps emin ep50 ep99 emax m50 m99 mmax mmean busy oops ovf pipe <<< "$parsed"
    projected="$(calc "b = $mmean / 1000 * ${gps_median[i]}; if (b > 1) b = 1; printf \"%.4f\", b")"
    echo "$arch,$n,2core,1,$pipe,$gps,$emin,$ep50,$ep99,$emax,$m50,$m99,$mmax,$mmean,$busy,$projected,$oops,$ovf,$(basename "$log")" >> "$csv"
    echo "2-core: $gps g/s (pipeline $pipe), search p99 $m99 ms, busy $busy measured, $projected projected"
    p99s+=("$ep99")
    maxes+=("$emax")
    lost=$((lost + oops + ovf))

    measured[i]=1
    gps_runs[i]="${run_gps[*]}"
    edges_p99[i]="$(max_of "${p99s[@]}")"
    edges_max[i]="$(max_of "${maxes[@]}")"
    ms_p99_full[i]="$(max_of "${ms99s[@]}")"
    ms_p99_weak[i]="$m99"
    busy_full[i]="$(max_of "${busys[@]}")"
    busy_weak[i]="$busy"
    busy_projected[i]="$projected"
    pipeline_weak[i]="$pipe"

    reasons=()
    if [[ ${edges_max[i]} -gt $EDGE_LIMIT ]]; then
        reasons+=("max edges ${edges_max[i]} > $EDGE_LIMIT")
    fi
    if [[ $lost -gt 0 ]]; then
        reasons+=("OOPS or NODE OVERFLOW")
    fi
    if calc "exit !($projected > $BUSY_LIMIT)"; then
        reasons+=("2-core projected busy $projected > $BUSY_LIMIT")
    fi
    if [[ ${#reasons[@]} -gt 0 ]]; then
        stop_reason[i]="$(printf '%s; ' "${reasons[@]}")"
        stop_reason[i]="${stop_reason[i]%; }"
        echo "stop: ${stop_reason[i]}"
        stopped=1
    fi
done

# The solver's first line names the GPU.
name="$(sed -n 's/^TARI\.Miner C29 solver .* on \(.*\) ([0-9]* GB, sm_[0-9]*)$/\1/p' "$out_dir/ntrims-${ntrims_values[0]}-run1.log" | head -n 1)"
[[ -z "$name" ]] || gpu_name="$name"

# Baseline and choice.
base=-1
for i in "${!ntrims_values[@]}"; do
    if [[ ${ntrims_values[$i]} -eq $default_ntrims && ${measured[$i]} -eq 1 ]]; then
        base=$i
    fi
done
chosen=-1
gain=()
for i in "${!ntrims_values[@]}"; do
    gain[i]=0
    [[ $base -ge 0 && $i -ne $base && ${measured[$i]} -eq 1 && -z "${stop_reason[$i]}" ]] || continue
    ok=1
    calc "exit !(${gps_median[$i]} >= ${gps_median[$base]} * (1 + $MIN_GAIN))" || ok=0
    for g in ${gps_runs[$i]}; do
        calc "exit !($g > ${gps_median[$base]})" || ok=0
    done
    if [[ $ok -eq 1 ]]; then
        gain[i]=1
        chosen=$i # values are highest first, so the last gain is the lowest
    fi
done

{
    echo "## ntrims sweep: $arch"
    echo
    echo "- GPU: $gpu_name, driver $driver, CUDA $cuda"
    echo "- solver: $solver_label, --count $count, $runs runs per ntrims (median), auto pipeline, ${warmup} s warm-up"
    echo "- 2-core check: CPUs $cpus ($cpus_source), $pin_label, second solver on device $load_device with --pipeline $load_pipeline"
    echo "- limits: max edges <= $EDGE_LIMIT, no OOPS / NODE OVERFLOW, 2-core projected busy <= $BUSY_LIMIT; gain >= 0.5% and every run above the default's median"
    echo "- busy = host cycle-search time / wall time. 2-core projected = the 2-core run's search ms per graph x the full-GPU median g/s, because a GPU shared with the second solver lowers the measured fraction"
    echo "- current default: $default_ntrims"
    echo
    echo "| arch | ntrims | g/s median | g/s runs | vs default | edges p99 | edges max | search ms p99 (full / 2-core) | busy full | busy 2-core (measured / projected) | 2-core pipeline | result |"
    echo "|---|---|---|---|---|---|---|---|---|---|---|---|"
    for i in "${!ntrims_values[@]}"; do
        n="${ntrims_values[$i]}"
        if [[ ${measured[$i]} -eq 0 ]]; then
            echo "| $arch | $n | | | | | | | | | | not run (stopped above) |"
            continue
        fi
        vs=""
        if [[ $base -ge 0 ]]; then
            vs="$(calc "printf \"%+.2f%%\", (${gps_median[$i]} / ${gps_median[$base]} - 1) * 100")"
        fi
        if [[ -n "${stop_reason[$i]}" ]]; then
            result="stop: ${stop_reason[$i]}"
        elif [[ $i -eq $base ]]; then
            result="default"
        elif [[ $i -eq $chosen ]]; then
            result="**chosen**"
        elif [[ ${gain[$i]} -eq 1 ]]; then
            result="gain"
        else
            result="no gain"
        fi
        busy_cell="$(calc "printf \"%.1f%% | %.1f%% / %.1f%%\", ${busy_full[$i]} * 100, ${busy_weak[$i]} * 100, ${busy_projected[$i]} * 100")"
        echo "| $arch | $n | ${gps_median[$i]} | ${gps_runs[$i]} | $vs | ${edges_p99[$i]} | ${edges_max[$i]} | ${ms_p99_full[$i]} / ${ms_p99_weak[$i]} | $busy_cell | ${pipeline_weak[$i]} | $result |"
    done
} > "$table"

echo
cat "$table"
echo
echo "raw logs and $(basename "$csv"): $out_dir"
if [[ $base -lt 0 ]]; then
    die "the current default ntrims $default_ntrims was not measured (a stop rule fired above it)"
fi
if [[ -n "${stop_reason[$base]}" ]]; then
    echo "warning: the current default ntrims $default_ntrims is already over a limit: ${stop_reason[$base]}" >&2
fi
if [[ $chosen -lt 0 ]]; then
    echo "chosen_ntrims=none"
    echo "No ntrims within the limits beats the default $default_ntrims by 0.5% or more; keep it."
    exit 0
fi
pick="${ntrims_values[$chosen]}"
echo "chosen_ntrims=$pick"
cat <<EOF

Next steps (docs/ntrims_sweep.md):
1. Recall comparison with the current binary at --ntrims $pick (reference stays at 50):
   $PYTHON tests/tari_c29_gpu_recall.py run --candidate bin/tari_c29_solver_$arch --reference bin/validation/tari_c29_solver_${arch}_reference --arch $arch --output-dir validation --parity-pipeline 2 --candidate-ntrims $pick
2. Ship: in build_flags/$arch.flags set the line
   -DTARI_C29_DEFAULT_NTRIMS=$pick
   (replace any existing -DTARI_C29_DEFAULT_NTRIMS= line), rebuild with ./build_solver.sh $arch,
   and run the recall comparison again without --candidate-ntrims.
EOF
