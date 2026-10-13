#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for arch in sm_86 sm_89 sm_120; do
    "$ROOT/build_solver.sh" "$arch"
    "$ROOT/build_pool_miner.sh" "$arch"
    "$ROOT/build_solver.sh" "$arch" reference
done

# The AMD (HIP) build is opt-in: it needs hipcc from ROCm.
if [[ "${TARI_BUILD_AMD:-0}" == "1" ]]; then
    "$ROOT/build_solver.sh" amd
    "$ROOT/build_pool_miner.sh" amd
    "$ROOT/build_solver.sh" amd reference
fi

echo "All Linux GPU backends built successfully."
