#!/usr/bin/env bash

set -e

cd "$(dirname "${BASH_SOURCE[0]}")"
. ./h-manifest.conf

miner_dir="$(pwd)"
if [[ -z "${CUSTOM_CONFIG_FILENAME:-}" || ! -d "$(dirname "$CUSTOM_CONFIG_FILENAME")" ]]; then
    CUSTOM_CONFIG_FILENAME="$miner_dir/miner.env"
fi
export CUSTOM_CONFIG_FILENAME

template="${TARI_WALLET:-${CUSTOM_TEMPLATE:-${CUSTOM_WALLET:-}}}"
wallet="$template"
template_worker=""
if [[ "$template" == *.* ]]; then
    wallet="${template%%.*}"
    template_worker="${template#*.}"
fi

pool="${TARI_POOL:-${CUSTOM_URL:-taric29-ca.luckypool.io:3111}}"
pool="${pool%%,*}"
pool="${pool#stratum+tcp://}"
pool="${pool#stratum://}"
pool="${pool#tcp://}"
pool="${pool#${pool%%[![:space:]]*}}"
pool="${pool%${pool##*[![:space:]]}}"

worker="${TARI_WORKER:-${template_worker:-${WORKER_NAME:-$(hostname)}}}"
password="${TARI_PASS:-${CUSTOM_PASS:-x}}"
devices="${TARI_DEVICES:-all}"
amd_devices="${TARI_AMD_DEVICES:-all}"
raw_extra=()
extra_args=()
if [[ -n "${CUSTOM_USER_CONFIG:-}" ]]; then
    read -r -a raw_extra <<< "$CUSTOM_USER_CONFIG"
fi
for token in "${raw_extra[@]}"; do
    case "$token" in
        TARI_DEVICES=*) devices="${token#TARI_DEVICES=}" ;;
        TARI_AMD_DEVICES=*) amd_devices="${token#TARI_AMD_DEVICES=}" ;;
        *) extra_args+=("$token") ;;
    esac
done

{
    printf 'TARI_POOL=%q\n' "$pool"
    printf 'TARI_WALLET=%q\n' "$wallet"
    printf 'TARI_WORKER=%q\n' "$worker"
    printf 'TARI_PASS=%q\n' "$password"
    printf 'TARI_DEVICES=%q\n' "$devices"
    printf 'TARI_AMD_DEVICES=%q\n' "$amd_devices"
    printf 'TARI_LOG_DIR=%q\n' "$(dirname "$CUSTOM_LOG_BASENAME")/workers"
    printf 'TARI_EXTRA_ARGS=('
    for arg in "${extra_args[@]}"; do
        printf ' %q' "$arg"
    done
    printf ' )\n'
} > "$CUSTOM_CONFIG_FILENAME"

MINER_API_PORT=${MINER_API_PORT:-${WEB_PORT:-0}}
MINER_LOG_BASENAME=${MINER_LOG_BASENAME:-$CUSTOM_LOG_BASENAME}
miner_ver() { :; }
miner_config_gen() { :; }
