#!/usr/bin/env bash
# Feeds pool miner speed lines through hiveos/h-stats.sh and checks that it
# reports the rolling rate and the accepted/rejected counters.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tari-hiveos-stats-test.XXXXXX")"
trap 'rm -rf -- "$TEMP_ROOT"' EXIT

mkdir -p "$TEMP_ROOT/bin" "$TEMP_ROOT/logs"
cat > "$TEMP_ROOT/bin/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
printf '0, 8.9, 00000000:01:00.0, 61, 45\n'
EOF
chmod +x "$TEMP_ROOT/bin/nvidia-smi"
: > "$TEMP_ROOT/miner.env"

# The last speed line wins, and the summary line must not match.
cat > "$TEMP_ROOT/logs/gpu0.log" <<'EOF'
connecting to pool.example:3333 as wallet.worker
speed 9.00 g/s | avg 9.00 g/s | graphs=135 cycles=0 submitted=0 accepted=0 rejected=0
share diff=100 target=50 nonce=0000000000000001
speed 13.65 g/s | avg 12.10 g/s | graphs=7260 cycles=12 submitted=3 accepted=2 rejected=1

--- summary ---
graphs=7300 elapsed=600.00s speed=12.167 g/s cycles=12 submitted=3 verify_failures=0
EOF

stats="$(
    PATH="$TEMP_ROOT/bin:$PATH" \
    CUSTOM_CONFIG_FILENAME="$TEMP_ROOT/miner.env" \
    TARI_LOG_DIR="$TEMP_ROOT/logs" \
    TARI_DEVICES=all \
        bash "$ROOT/hiveos/h-stats.sh"
)"

fail=0
expect() {
    if [[ "$stats" != *"$1"* ]]; then
        echo "expected $1 in h-stats output" >&2
        fail=1
    fi
}
expect '"hs":[13.650]'
expect '"ar":[2,1]'
expect '"temp":[61]'
if ((fail)); then
    echo "$stats" >&2
    exit 1
fi
echo "hiveos stats parse tests passed"
