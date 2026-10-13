#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"
. ./h-manifest.conf

if [[ -z "${CUSTOM_CONFIG_FILENAME:-}" || ! -f "$CUSTOM_CONFIG_FILENAME" ]]; then
    CUSTOM_CONFIG_FILENAME="$script_dir/miner.env"
fi
[[ -f "$CUSTOM_CONFIG_FILENAME" ]] && . "$CUSTOM_CONFIG_FILENAME"

TARI_DEVICES="${TARI_DEVICES:-all}"
TARI_LOG_DIR="${TARI_LOG_DIR:-$(dirname "$CUSTOM_LOG_BASENAME")/workers}"
# HiveOS writes per-GPU temperatures and fans here; AMD stats come from it.
GPU_STATS_JSON="${GPU_STATS_JSON:-/run/hive/gpu-stats.json}"

device_selected() {
    local index="$1"
    local requested=",${TARI_DEVICES//[[:space:]]/},"
    [[ "${TARI_DEVICES,,}" == "all" || "$requested" == *",$index,"* ]]
}

supported_cap() {
    case "$1" in
        8.6|8.9|12.0) return 0 ;;
        *) return 1 ;;
    esac
}

json_number_array() {
    local out="[" sep="" value
    for value in "$@"; do
        case "$value" in
            ''|*[!0-9.-]*) value=0 ;;
        esac
        out+="$sep$value"
        sep=,
    done
    printf '%s]' "$out"
}

# read_log_stats LOG_FILE
#   Sets rate, gpu_accepted and gpu_rejected from one worker log.
read_log_stats() {
    local log_file="$1" log_window log_size log_start log_skip
    rate=0
    gpu_accepted=0
    gpu_rejected=0
    if [[ -f "$log_file" && $((now - $(stat -c %Y "$log_file" 2>/dev/null || echo 0))) -le 180 ]]; then
        # Only a whole line in the miner's own report format counts, and the
        # fields are read by position. The miner logs pool text after a prefix
        # such as "pool error:" and caps it well below the stdio buffer size, so
        # pool text should never be written as a line of its own. The only
        # field allowed after t= is stale=. Over-long numbers are ignored. A
        # report more than 90 s old, or more than 30 s in the future, does not
        # set the rate; with no fresh report the rate is 0, while accepted and
        # rejected come from the newest report line. Only the last 1 MiB
        # of the log is read, so a flooded log stays cheap to parse. When the
        # log is bigger than that, reading starts mid-line, so the first line
        # read is dropped: its tail could be pool text that looks like a report.
        log_window=1048576
        log_size="$(stat -c %s "$log_file" 2>/dev/null || echo 0)"
        log_start=1
        log_skip=0
        if ((log_size > log_window)); then
            log_start=$((log_size - log_window + 1))
            log_skip=1
        fi
        read -r rate gpu_accepted gpu_rejected < <(tail -c "+$log_start" "$log_file" | LC_ALL=C awk -v now="$now" -v skip="$log_skip" '
            NR == 1 && skip == 1 { next }
            /^speed [0-9]+\.[0-9]+ g\/s \| avg [0-9]+\.[0-9]+ g\/s \| graphs=[0-9]+ cycles=[0-9]+ submitted=[0-9]+ accepted=[0-9]+ rejected=[0-9]+ t=[0-9]+( stale=[0-9]+)?$/ {
                a = substr($12, 10)
                r = substr($13, 10)
                t = substr($14, 3)
                if (length($2) > 12 || length(a) > 15 || length(r) > 15 || length(t) > 12) next
                accepted = a
                rejected = r
                # Only a fresh line sets the rate, so a stale line, or a line
                # cut off mid-write (t=17...), cannot hide the latest report.
                if (now - t <= 90 && t - now <= 30) {
                    rate = $2
                    fresh = 1
                }
            }
            END {
                if (!fresh) rate = 0
                printf "%.3f %.0f %.0f\n", rate + 0, accepted + 0, rejected + 0
            }
        ')
    fi
}

rates=()
temps=()
fans=()
buses=()
accepted=0
rejected=0
now="$(date +%s)"

# On a rig without NVIDIA GPUs nvidia-smi may be missing, or print an error to
# stdout and fail; then there is nothing to read.
nvidia_output="$(nvidia-smi --query-gpu=index,compute_cap,pci.bus_id,temperature.gpu,fan.speed --format=csv,noheader,nounits 2>/dev/null)" || nvidia_output=""
while IFS=',' read -r raw_index raw_cap raw_bus raw_temp raw_fan; do
    index="$(xargs <<< "${raw_index:-}")"
    cap="$(xargs <<< "${raw_cap:-}")"
    bus="$(xargs <<< "${raw_bus:-}")"
    temp="$(xargs <<< "${raw_temp:-0}")"
    fan="$(xargs <<< "${raw_fan:-0}")"
    [[ -n "$index" ]] || continue
    device_selected "$index" || continue
    supported_cap "$cap" || continue

    log_file="$TARI_LOG_DIR/gpu$index.log"
    read_log_stats "$log_file"

    bus="${bus#*:}"
    bus="${bus%%:*}"
    bus="${bus#0x}"
    case "$bus" in
        ''|*[!0-9A-Fa-f]*) bus=0 ;;
        *) bus=$((16#$bus)) ;;
    esac
    temp="${temp%%.*}"
    fan="${fan%%.*}"
    case "$temp" in ''|*[!0-9]*) temp=0 ;; esac
    case "$fan" in ''|*[!0-9]*) fan=0 ;; esac

    rates+=("$rate")
    temps+=("$temp")
    fans+=("$fan")
    buses+=("$bus")
    accepted=$((accepted + gpu_accepted))
    rejected=$((rejected + gpu_rejected))
done <<< "$nvidia_output"

# AMD workers. start-c29.sh writes amd<index>.log for each AMD GPU it starts
# (h-run.sh clears old logs first), so the logs name the AMD GPUs in use.
# Temperature, fan and bus come from the HiveOS GPU stats: the AMD entries
# there, in bus order, are taken to be HIP devices 0, 1, 2, ... (the HIP
# runtime also lists GPUs in bus order). Without the stats file, or without
# jq, they are reported as 0.
amd_hw=()
if [[ -f "$GPU_STATS_JSON" ]] && command -v jq >/dev/null 2>&1; then
    while read -r line; do
        amd_hw+=("$line")
    done < <(jq -r 'if (.brand | type) == "array" then
            range(0; .brand | length) as $i
            | select(.brand[$i] == "amd")
            | "\(.temp[$i] // 0) \(.fan[$i] // 0) \(.busids[$i] // 0)"
        else empty end' "$GPU_STATS_JSON" 2>/dev/null || true)
fi
amd_indexes="$(ls "$TARI_LOG_DIR" 2>/dev/null | sed -n -E 's/^amd(0|[1-9][0-9]*)\.log$/\1/p' | sort -n)"
while read -r index; do
    [[ -n "$index" ]] || continue
    read_log_stats "$TARI_LOG_DIR/amd$index.log"

    temp=0
    fan=0
    bus=0
    if ((index < ${#amd_hw[@]})); then
        read -r temp fan bus <<< "${amd_hw[$index]}"
    fi
    # HiveOS bus ids look like 03:00.0, sometimes with a 0000: domain.
    bus="${bus%:*}"
    bus="${bus##*:}"
    case "$bus" in
        ''|*[!0-9A-Fa-f]*) bus=0 ;;
        *) bus=$((16#$bus)) ;;
    esac
    temp="${temp%%.*}"
    fan="${fan%%.*}"
    case "$temp" in ''|*[!0-9]*) temp=0 ;; esac
    case "$fan" in ''|*[!0-9]*) fan=0 ;; esac

    rates+=("$rate")
    temps+=("$temp")
    fans+=("$fan")
    buses+=("$bus")
    accepted=$((accepted + gpu_accepted))
    rejected=$((rejected + gpu_rejected))
done <<< "$amd_indexes"

if [[ ${#rates[@]} -eq 0 ]]; then
    rates=(0)
    temps=(0)
    fans=(0)
    buses=(0)
fi

khs="$(awk 'BEGIN { total=0; for (i=1; i<ARGC; i++) total+=ARGV[i]; printf "%.6f", total/1000 }' "${rates[@]}")"
uptime=0
pid="$(pgrep -fo 'tari_c29_pool_miner_(sm_|amd)' 2>/dev/null || true)"
if [[ -n "$pid" ]]; then
    uptime="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ' || echo 0)"
fi
case "$uptime" in ''|*[!0-9]*) uptime=0 ;; esac

stats="{\"hs\":$(json_number_array "${rates[@]}"),\"hs_units\":\"hs\",\"temp\":$(json_number_array "${temps[@]}"),\"fan\":$(json_number_array "${fans[@]}"),\"uptime\":$uptime,\"ver\":\"$CUSTOM_VERSION\",\"ar\":[$accepted,$rejected],\"algo\":\"cuckaroo29\",\"bus_numbers\":$(json_number_array "${buses[@]}")}"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf '%s\n' "$stats"
fi
