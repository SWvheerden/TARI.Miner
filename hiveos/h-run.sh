#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
. ./h-manifest.conf

if [[ -z "${CUSTOM_CONFIG_FILENAME:-}" || ! -d "$(dirname "$CUSTOM_CONFIG_FILENAME")" ]]; then
    CUSTOM_CONFIG_FILENAME="$(pwd)/miner.env"
fi
export CUSTOM_CONFIG_FILENAME

./h-config.sh
# shellcheck disable=SC1090
set -a
. "$CUSTOM_CONFIG_FILENAME"
set +a

if [[ -z "${TARI_WALLET:-}" ]]; then
    echo "ERROR: Set the HiveOS wallet/template to your Tari wallet address." >&2
    exit 2
fi

mkdir -p "$TARI_LOG_DIR" "$(dirname "$CUSTOM_LOG_BASENAME")"
rm -f "$TARI_LOG_DIR"/gpu*.log "$TARI_LOG_DIR"/amd*.log

launcher_args=("${TARI_EXTRA_ARGS[@]}" --pass "$TARI_PASS")
exec > >(tee -a "$CUSTOM_LOG_BASENAME.log") 2>&1
exec ./start-c29.sh "${launcher_args[@]}"
