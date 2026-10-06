#!/usr/bin/env bash
# Dry-run regressions for tools/ntrims_sweep.sh: parsing, stop rules, choice
# and failure handling, using tests/ntrims_sweep_fake_solver.py instead of a
# GPU. tests/ntrims_sweep_test.ps1 runs the same cases against the PowerShell
# sweep.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tari-c29-ntrims-sweep-test.XXXXXX")"
trap 'rm -rf -- "$TEMP_ROOT"' EXIT

failures=0
checks=0
fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

# sweep NAME SCENARIO [ARGS...]: runs a dry-run sweep; output in $TEMP_ROOT/NAME.
sweep() {
    local name="$1" scenario="$2"
    shift 2
    TARI_FAKE_SOLVER_SCENARIO="$scenario" TARI_FAKE_SOLVER_STATE="$TEMP_ROOT/$name.state" \
        bash "$ROOT/tools/ntrims_sweep.sh" --dry-run --arch sm_89 --runs 3 \
        --out "$TEMP_ROOT/$name" "$@" > "$TEMP_ROOT/$name.out" 2>&1
}

# expect_choice NAME SCENARIO CHOSEN [ARGS...]
expect_choice() {
    local name="$1" scenario="$2" chosen="$3"
    shift 3
    checks=$((checks + 1))
    if ! sweep "$name" "$scenario" "$@"; then
        fail "$name: sweep failed"
        cat "$TEMP_ROOT/$name.out" >&2
        return
    fi
    if ! grep -qx "chosen_ntrims=$chosen" "$TEMP_ROOT/$name.out"; then
        fail "$name: expected chosen_ntrims=$chosen"
        cat "$TEMP_ROOT/$name.out" >&2
    fi
}

# expect_row NAME NTRIMS TEXT: the table row for NTRIMS contains TEXT.
expect_row() {
    local name="$1" ntrims="$2" text="$3"
    checks=$((checks + 1))
    if ! grep -F "| sm_89 | $ntrims |" "$TEMP_ROOT/$name/sweep.md" | grep -qF -- "$text"; then
        fail "$name: row $ntrims lacks [$text]"
        cat "$TEMP_ROOT/$name/sweep.md" >&2
    fi
}

# expect_failure NAME SCENARIO MESSAGE [ARGS...]
expect_failure() {
    local name="$1" scenario="$2" message="$3"
    shift 3
    checks=$((checks + 1))
    if sweep "$name" "$scenario" "$@"; then
        fail "$name: sweep should have failed"
    elif ! grep -qF -- "$message" "$TEMP_ROOT/$name.out"; then
        fail "$name: expected [$message] in the output"
        cat "$TEMP_ROOT/$name.out" >&2
    fi
}

expect_choice edges edges 42 --default-ntrims 50
expect_row edges 50 "| 13.650 | 13.650 13.650 13.650 | +0.00% |"
expect_row edges 50 "| default |"
expect_row edges 48 "| no gain |"
expect_row edges 46 "| gain |"
expect_row edges 42 "| **chosen** |"
expect_row edges 40 "stop: max edges 556939 > 524288"
expect_row edges 36 "not run (stopped above)"
checks=$((checks + 1))
# 6 measured ntrims (50 to 40), 3 full runs and one 2-core run each, plus the header.
rows="$(wc -l < "$TEMP_ROOT/edges/sweep.csv" | tr -d ' ')"
[[ "$rows" == 25 ]] || fail "edges: expected 25 CSV lines, got $rows"
checks=$((checks + 1))
grep -q "^sm_89,44,2core,1,2,13.773,82387,164775,296595,329550," "$TEMP_ROOT/edges/sweep.csv" \
    || fail "edges: 2-core CSV row for 44"
checks=$((checks + 1))
grep -qF -- "--candidate-ntrims 42" "$TEMP_ROOT/edges.out" || fail "edges: recall command"
checks=$((checks + 1))
grep -qx "   -DTARI_C29_DEFAULT_NTRIMS=42" "$TEMP_ROOT/edges.out" || fail "edges: flags line"

expect_choice overflow overflow 46 --default-ntrims 50
expect_row overflow 44 "stop: OOPS or NODE OVERFLOW"

expect_choice busy busy 40 --default-ntrims 50
# The measured fraction is half the projection (a shared GPU), so only the
# projection reaches the limit.
expect_row busy 36 "stop: 2-core projected busy 0.4500 > 0.40"
expect_row busy 40 "| 17.5% | 17.5% / 35.0% | 2 | **chosen** |"

expect_choice nogain nogain none --default-ntrims 50
expect_row nogain 42 "| no gain |"

# 48 has the best median but one run below the default's median.
expect_choice noisy noisy 46 --default-ntrims 50
expect_row noisy 48 "| 14.000 | 14.000 13.000 14.000 | +2.56% |"
expect_row noisy 48 "| no gain |"

# The default comes from TARI_ARCH_FLAGS / build_flags, like the recall test,
# and is added to the list when missing.
TARI_ARCH_FLAGS="-DTARI_C29_DEFAULT_NTRIMS=48" expect_choice default48 edges 42 --ntrims "50 46 44 42 40"
expect_row default48 48 "| default |"
expect_row default48 50 "| -0.30% |"

# 2-core CPUs: two different physical cores from the sysfs topology (sorted
# numerically, so cpu10 does not come before cpu2), --cpus, or 0,1.
make_topology() {
    local dir="$1" n
    shift
    n=0
    for core in "$@"; do
        mkdir -p "$dir/cpu$n/topology"
        echo 0 > "$dir/cpu$n/topology/physical_package_id"
        echo "$core" > "$dir/cpu$n/topology/core_id"
        n=$((n + 1))
    done
}
make_topology "$TEMP_ROOT/smt-adjacent" 0 0 1 1 2 2 3 3 4 4 7
make_topology "$TEMP_ROOT/smt-split" 0 1 0 1
expect_cpus() {
    local name="$1" expected="$2"
    shift 2
    checks=$((checks + 1))
    if ! sweep "$name" nogain --default-ntrims 50 --ntrims "50" "$@"; then
        fail "$name: sweep failed"
        cat "$TEMP_ROOT/$name.out" >&2
    elif ! grep -qF -- "- 2-core check: CPUs $expected" "$TEMP_ROOT/$name/sweep.md"; then
        fail "$name: expected [CPUs $expected]"
        cat "$TEMP_ROOT/$name/sweep.md" >&2
    fi
}
TARI_SWEEP_CPU_SYSFS="$TEMP_ROOT/smt-adjacent" expect_cpus cpus-adjacent "0,2 (two different physical cores)"
TARI_SWEEP_CPU_SYSFS="$TEMP_ROOT/smt-split" expect_cpus cpus-split "0,1 (two different physical cores)"
TARI_SWEEP_CPU_SYSFS="$TEMP_ROOT/missing" expect_cpus cpus-unknown "0,1 (CPU topology unknown"
TARI_SWEEP_CPU_SYSFS="$TEMP_ROOT/smt-adjacent" expect_cpus cpus-override "1,0 (from --cpus)" --cpus 1,0

expect_failure old old "is the solver built with the ntrims statistics?" --default-ntrims 50
expect_failure crash crash "solver run failed" --default-ntrims 50
expect_failure loaddies loaddies "2-core load solver exited early" --default-ntrims 50
expect_failure stopabove edges "was not measured" --default-ntrims 36 --ntrims "40 36"
expect_failure odd edges "ntrims must be even" --ntrims "50 47"
expect_failure noarch edges "--arch must be" --arch sm_75
checks=$((checks + 1))
if bash "$ROOT/tools/ntrims_sweep.sh" --arch sm_89 --solver "$TEMP_ROOT/missing-solver" \
        > "$TEMP_ROOT/nosolver.out" 2>&1; then
    fail "nosolver: sweep should have failed"
elif ! grep -qF "solver not found" "$TEMP_ROOT/nosolver.out"; then
    fail "nosolver: expected [solver not found]"
    cat "$TEMP_ROOT/nosolver.out" >&2
fi
expect_failure badcount edges "not a whole number" --count 2k

if [[ $failures -ne 0 ]]; then
    echo "$failures of $checks ntrims sweep checks failed" >&2
    exit 1
fi
echo "PASS: $checks ntrims sweep checks"
