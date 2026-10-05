#!/usr/bin/env bash
# Feeds pool miner speed lines through hiveos/h-stats.sh and checks that it
# reports the rolling rate and the accepted/rejected counters, and that pool
# text or stale lines cannot change them.
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

now="$(date +%s)"
fail=0

# Runs h-stats.sh against the log on stdin and checks the output contains
# each expected string.
check() {
    local name="$1"
    shift
    cat > "$TEMP_ROOT/logs/gpu0.log"
    local stats
    stats="$(
        PATH="$TEMP_ROOT/bin:$PATH" \
        CUSTOM_CONFIG_FILENAME="$TEMP_ROOT/miner.env" \
        TARI_LOG_DIR="$TEMP_ROOT/logs" \
        TARI_DEVICES=all \
            bash "$ROOT/hiveos/h-stats.sh"
    )"
    local expected
    for expected in "$@"; do
        if [[ "$stats" != *"$expected"* ]]; then
            echo "FAIL $name: expected $expected in $stats" >&2
            fail=1
        fi
    done
}

# The last report wins. Pool text after it, an old-format line, an over-long
# counter and the summary line must all be ignored.
check "latest report" '"hs":[13.650]' '"ar":[2,1]' '"temp":[61]' <<EOF
connecting to pool.example:3333 as wallet.worker
speed 9.00 g/s | avg 9.00 g/s | graphs=135 cycles=0 submitted=0 accepted=0 rejected=0 t=$((now - 30))
share diff=100 target=50 nonce=0000000000000001
speed 13.65 g/s | avg 12.10 g/s | graphs=7260 cycles=12 submitted=3 accepted=2 rejected=1 t=$now
pool error: {"id":999,"error":"speed 0 g/s accepted=0 rejected=0"}
share rejected: {"id":7,"error":"speed 0.00 g/s | avg 0.00 g/s | graphs=0 cycles=0 submitted=0 accepted=0 rejected=0 t=$now"}
speed 1.00 g/s | graphs=1 cycles=0 submitted=0 accepted=5 rejected=5
speed 99.00 g/s | avg 1.00 g/s | graphs=1 cycles=0 submitted=0 accepted=99999999999999999999 rejected=0 t=$now
speed 1e300 g/s | avg 1.00 g/s | graphs=1 cycles=0 submitted=0 accepted=0 rejected=0 t=$now

--- summary ---
graphs=7300 elapsed=600.00s speed=12.167 g/s cycles=12 submitted=3 verify_failures=0
EOF

# A report older than 90 s means the miner stopped reporting; the counters
# are still the last known ones.
check "stale report" '"hs":[0.000]' '"ar":[2,1]' <<EOF
speed 13.65 g/s | avg 12.10 g/s | graphs=7260 cycles=12 submitted=3 accepted=2 rejected=1 t=$((now - 200))
pool error: {"id":999,"error":"still connected"}
EOF

# Only pool text: nothing is reported.
check "forged only" '"hs":[0.000]' '"ar":[0,0]' <<EOF
pool error: {"id":999,"error":"speed 50 g/s accepted=7 rejected=0"}
EOF

if ((fail)); then
    exit 1
fi
echo "hiveos stats parse tests passed"
