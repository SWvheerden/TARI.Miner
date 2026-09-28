#!/usr/bin/env bash
set -euo pipefail

# Linux build for the LuckyPool-compatible Tari C29 miner.
# Default sm_86 works with the PATH CUDA 11.5 toolkit and includes PTX for
# forward JIT. With a newer toolkit, pass NVCC=/path/to/nvcc and sm_89/sm_120.

ARCH="${1:-sm_86}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$ROOT/bin"
OUTPUT="$ROOT/bin/tari_c29_pool_miner_$ARCH"
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
read_arch_flags "$ROOT" "$ARCH"
EXTRA_FLAGS=()
if [[ ${#ARCH_FLAGS[@]} -gt 0 ]]; then
    EXTRA_FLAGS=("${ARCH_FLAGS[@]}")
fi

echo "Building tari_c29_pool_miner_linux for $ARCH ..."
print_arch_flags "$ARCH"
"$NVCC" "${HOST_FLAGS[@]}" -O3 -std="$STD" --default-stream per-thread -DXBITS="$XBITS" -DIDXSHIFT="$IDXSHIFT" -DGRAPH_UNION_SKIP=1 -DRECOVERY_SMALL_OUTPUT=1 -DSEEDA_REHASH=1 \
    "${EXTRA_FLAGS[@]}" \
    -maxrregcount="$MAXRREGCOUNT" -Xptxas -flcm=cg \
    -gencode "arch=$COMPUTE,code=$ARCH" \
    -gencode "arch=$COMPUTE,code=$COMPUTE" \
    -I"$ROOT" \
    -I"$ROOT/compat" \
    -I"$CUCKAROO" \
    -I"$CRYPTO" \
    "$ROOT/tari_c29_pool_miner.cu" \
    "$ROOT/tari_c29.cpp" \
    "$CRYPTO/blake2b-ref.c" \
    -o "$OUTPUT"

echo "BUILD OK -> $OUTPUT"
