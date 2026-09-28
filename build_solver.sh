#!/usr/bin/env bash
set -euo pipefail

# Linux build for the standalone Tari C29 solver/benchmark.
# Default sm_86 works with the PATH CUDA 11.5 toolkit and includes PTX for
# forward JIT. With a newer toolkit, pass NVCC=/path/to/nvcc and sm_89/sm_120.

ARCH="${1:-sm_86}"
BUILD_ARCH="${ARCH#sm_}"
PROFILE="${2:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$ROOT/bin"
CUCKOO_ROOT="${CUCKOO_ROOT:-"$ROOT/third_party/cuckoo"}"
CUCKAROO="$CUCKOO_ROOT/src/cuckaroo"
CRYPTO="$CUCKOO_ROOT/src/crypto"
NVCC="${NVCC:-nvcc}"
NVCC_HOST="${NVCC_HOST:-}"
XBITS="${XBITS:-7}"
IDXSHIFT="${IDXSHIFT:-9}"
MAXRREGCOUNT="${MAXRREGCOUNT:-96}"
STD="${STD:-c++17}"

COMPUTE="compute_${ARCH#sm_}"
HOST_FLAGS=()
if [[ -n "$NVCC_HOST" ]]; then
    HOST_FLAGS=(-ccbin "$NVCC_HOST" --allow-unsupported-compiler)
fi
# shellcheck source=build_flags/read_arch_flags.sh
source "$ROOT/build_flags/read_arch_flags.sh"
PROFILE_FLAGS=()
EXTRA_FLAGS=()
case "$PROFILE" in
    release)
        OUTPUT="$ROOT/bin/tari_c29_solver_$ARCH"
        PROFILE_FLAGS=(-DGRAPH_UNION_SKIP=1 -DRECOVERY_SMALL_OUTPUT=1 -DSEEDA_REHASH=1)
        read_arch_flags "$ROOT" "$ARCH"
        if [[ ${#ARCH_FLAGS[@]} -gt 0 ]]; then
            EXTRA_FLAGS=("${ARCH_FLAGS[@]}")
        fi
        ;;
    reference)
        mkdir -p "$ROOT/bin/validation"
        OUTPUT="$ROOT/bin/validation/tari_c29_solver_${ARCH}_reference"
        PROFILE_FLAGS=(-DTARI_C29_REFERENCE_BUILD=1 -DGRAPH_UNION_SKIP=0 -DRECOVERY_SMALL_OUTPUT=0 -DSEEDA_REHASH=0 -DSKIP_LATE_NULL_CHECKS=0 -DWARP_DST_ATOMICS_LATE=0 -DTARI_C29_DEFAULT_NTRIMS=50 -DSEEDB_REVERSE_LOOP=0 -DROUND0_DST_HASH_DYNAMIC_BITS=0 -DROUND0_DST_HASH_DYNAMIC_PROBES=8 -DROUND0_DST_HASH_FALLBACK_PLAIN=0 -DROUND0_DST_HASH_REPLAY_NORMAL_LOAD=0 -DROUND0_DST_HASH_REVERSE_INSERT=0 -DFUSE_FINAL_TAIL_CURRENT=0 -DFUSE_FINAL_TAIL_COUNT_NORMAL_LOAD=0 -DROUND1_COUNT_NORMAL_LOAD=0 -DROUND23_COUNT_NORMAL_LOAD=0 -DROUND23_TPB=1024)
        ;;
    *)
        echo "Unknown solver profile '$PROFILE'. Use release or reference." >&2
        exit 2
        ;;
esac

echo "Building tari_c29_solver_linux for $ARCH profile=$PROFILE ..."
if [[ "$PROFILE" == "release" ]]; then
    print_arch_flags "$ARCH"
fi
"$NVCC" "${HOST_FLAGS[@]}" -O3 -std="$STD" --default-stream per-thread -DXBITS="$XBITS" -DIDXSHIFT="$IDXSHIFT" -DTARI_C29_BUILD_ARCH="$BUILD_ARCH" \
    "${PROFILE_FLAGS[@]}" \
    "${EXTRA_FLAGS[@]}" \
    -maxrregcount="$MAXRREGCOUNT" -Xptxas -flcm=cg \
    -gencode "arch=$COMPUTE,code=$ARCH" \
    -gencode "arch=$COMPUTE,code=$COMPUTE" \
    -I"$ROOT" \
    -I"$ROOT/compat" \
    -I"$CUCKAROO" \
    -I"$CRYPTO" \
    "$ROOT/tari_c29_solver.cu" \
    "$ROOT/tari_c29.cpp" \
    "$CRYPTO/blake2b-ref.c" \
    -o "$OUTPUT"

echo "BUILD OK -> $OUTPUT"
