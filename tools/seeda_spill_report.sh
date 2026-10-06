#!/usr/bin/env bash
set -euo pipefail

# Register and spill report for the SeedA kernel in each SeedA mode.
#
#   tools/seeda_spill_report.sh [ARCH...]        (default: sm_86 sm_89 sm_120)
#
# Compiles the device code of the release solver and the pool miner with
# -Xptxas -v for every arch and mode, and prints a Markdown table of the
# SeedA registers, spill stores, spill loads and stack frame (local memory).
# The flags match build_solver.sh / build_pool_miner.sh: release profile,
# build_flags/ARCH.flags (or TARI_ARCH_FLAGS), then the mode's flags.
#
# Environment: NVCC (default nvcc), MAXRREGCOUNT (default 96), and
# SEEDA_SASS_DIR: when set, the SeedA SASS of each build is written there.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NVCC="${NVCC:-nvcc}"
MAXRREGCOUNT="${MAXRREGCOUNT:-96}"
CUCKOO_ROOT="${CUCKOO_ROOT:-"$ROOT/third_party/cuckoo"}"
ARCHS=("$@")
if [[ ${#ARCHS[@]} -eq 0 ]]; then
    ARCHS=(sm_86 sm_89 sm_120)
fi
MODES=(
    "-DSEEDA_REHASH=0"
    "-DSEEDA_REHASH=1"
    "-DSEEDA_REHASH=1 -DSEEDA_CHECKPOINT=8"
    "-DSEEDA_REHASH=1 -DSEEDA_CHECKPOINT=16"
    "-DSEEDA_REHASH=1 -DSEEDA_CHECKPOINT=32"
)
# shellcheck source=build_flags/read_arch_flags.sh
source "$ROOT/build_flags/read_arch_flags.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
if [[ -n "${SEEDA_SASS_DIR:-}" ]]; then
    mkdir -p "$SEEDA_SASS_DIR"
fi

echo "| Arch | Binary | Mode | Registers | Spill stores (B) | Spill loads (B) | Stack frame (B) |"
echo "|------|--------|------|-----------|------------------|-----------------|-----------------|"
for arch in "${ARCHS[@]}"; do
    read_arch_flags "$ROOT" "$arch"
    for binary in solver pool_miner; do
        if [[ "$binary" == solver ]]; then
            source_file="$ROOT/tari_c29_solver.cu"
            binary_flags=(-DTARI_C29_BUILD_ARCH="${arch#sm_}")
        else
            source_file="$ROOT/tari_c29_pool_miner.cu"
            binary_flags=()
        fi
        for mode in "${MODES[@]}"; do
            read -r -a mode_flags <<< "$mode"
            name="${arch}_${binary}_$(echo "$mode" | tr -d ' =-' | sed 's/DSEEDA_//g')"
            "$NVCC" -O3 -std=c++17 --default-stream per-thread -DXBITS=7 -DIDXSHIFT=9 \
                "${binary_flags[@]}" \
                -DGRAPH_UNION_SKIP=1 -DRECOVERY_SMALL_OUTPUT=1 \
                "${ARCH_FLAGS[@]}" \
                "${mode_flags[@]}" \
                -maxrregcount="$MAXRREGCOUNT" -Xptxas -flcm=cg -Xptxas -v \
                -cubin -arch="$arch" \
                -I"$ROOT" -I"$ROOT/compat" \
                -I"$CUCKOO_ROOT/src/cuckaroo" -I"$CUCKOO_ROOT/src/crypto" \
                "$source_file" -o "$WORK/$name.cubin" > "$WORK/$name.log" 2>&1 || {
                    cat "$WORK/$name.log" >&2
                    exit 1
                }
            stats="$(awk '
                /Compiling entry function .*_Z5SeedA/ { found = 1; next }
                found && /bytes stack frame/ { stack = $1; stores = $5; loads = $9 }
                found && /Used [0-9]+ registers/ {
                    for (i = 1; i < NF; i++) if ($i == "Used") regs = $(i + 1)
                    print regs " | " stores " | " loads " | " stack
                    exit
                }' "$WORK/$name.log")"
            if [[ -z "$stats" ]]; then
                echo "No SeedA ptxas report for $name" >&2
                cat "$WORK/$name.log" >&2
                exit 1
            fi
            echo "| $arch | $binary | \`$mode\` | $stats |"
            if [[ -n "${SEEDA_SASS_DIR:-}" ]]; then
                cuobjdump -sass "$WORK/$name.cubin" | awk '
                    /Function : / { keep = ($0 ~ /_Z5SeedA/) }
                    keep' > "$SEEDA_SASS_DIR/$name.sass"
            fi
        done
    done
done
