#!/usr/bin/env bash
# Regression checks for build_flags/read_arch_flags.sh, the reader behind
# build_solver.sh and build_pool_miner.sh. tests/build_flags_test.ps1 runs the
# same cases against the Windows reader.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tari-c29-build-flags-test.XXXXXX")"
trap 'rm -rf -- "$TEMP_ROOT"' EXIT
PYTHON="${PYTHON:-python3}"

# shellcheck source=build_flags/read_arch_flags.sh
source "$ROOT/build_flags/read_arch_flags.sh"

failures=0
checks=0
expect() {
    local label="$1" root="$2" arch="$3" expected="$4" actual
    checks=$((checks + 1))
    read_arch_flags "$root" "$arch"
    actual="${ARCH_FLAGS[*]:-}"
    if [[ "$actual" != "$expected" ]]; then
        echo "FAIL: $label: expected [$expected], got [$actual]" >&2
        failures=$((failures + 1))
    fi
}

mkdir -p "$TEMP_ROOT/build_flags"
printf '# header\r\n\r\n  -DQ=1   # inline\r\n#-DZ=2\r\n\t-DR=3 \t\r\n  # -DY=4\r\n-DS=5' \
    > "$TEMP_ROOT/build_flags/sm_crlf.flags"
printf '# header\n\n  -DQ=1   # inline\n#-DZ=2\n\t-DR=3 \t\n  # -DY=4\n-DS=5\n' \
    > "$TEMP_ROOT/build_flags/sm_lf.flags"
: > "$TEMP_ROOT/build_flags/sm_empty.flags"

unset TARI_ARCH_FLAGS
expect "CRLF file" "$TEMP_ROOT" sm_crlf "-DQ=1 -DR=3 -DS=5"
expect "LF file" "$TEMP_ROOT" sm_lf "-DQ=1 -DR=3 -DS=5"
expect "empty file" "$TEMP_ROOT" sm_empty ""
expect "missing file" "$TEMP_ROOT" sm_missing ""

# The committed files must read the same as the recall test's parser, which
# is what decides the expected compiled_ntrims.
for flags_file in "$ROOT"/build_flags/*.flags; do
    arch="$(basename "$flags_file" .flags)"
    expected="$("$PYTHON" -c 'import sys; sys.path.insert(0, sys.argv[1]); import tari_c29_gpu_recall as r; print(" ".join(r.parse_arch_flags(open(sys.argv[2], encoding="utf-8").read())))' "$ROOT/tests" "$flags_file")"
    expect "committed $arch" "$ROOT" "$arch" "$expected"
done

export TARI_ARCH_FLAGS=$'  -DA=1\t-DB=2  '
expect "TARI_ARCH_FLAGS replaces the file" "$TEMP_ROOT" sm_crlf "-DA=1 -DB=2"
expect "TARI_ARCH_FLAGS without a file" "$TEMP_ROOT" sm_missing "-DA=1 -DB=2"
TARI_ARCH_FLAGS=" "
expect "blank TARI_ARCH_FLAGS means no flags" "$TEMP_ROOT" sm_crlf ""
TARI_ARCH_FLAGS=""
expect "empty TARI_ARCH_FLAGS is ignored" "$TEMP_ROOT" sm_lf "-DQ=1 -DR=3 -DS=5"
unset TARI_ARCH_FLAGS

if [[ $failures -ne 0 ]]; then
    echo "$failures of $checks build flag checks failed" >&2
    exit 1
fi
echo "PASS: $checks build flag reader checks"
