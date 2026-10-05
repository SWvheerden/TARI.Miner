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

rates=()
temps=()
fans=()
buses=()
accepted=0
rejected=0
now="$(date +%s)"

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
done < <(nvidia-smi --query-gpu=index,compute_cap,pci.bus_id,temperature.gpu,fan.speed --format=csv,noheader,nounits 2>/dev/null || true)

if [[ ${#rates[@]} -eq 0 ]]; then
    rates=(0)
    temps=(0)
    fans=(0)
    buses=(0)
fi

khs="$(awk 'BEGIN { total=0; for (i=1; i<ARGC; i++) total+=ARGV[i]; printf "%.6f", total/1000 }' "${rates[@]}")"
uptime=0
pid="$(pgrep -fo 'tari_c29_pool_miner_sm_' 2>/dev/null || true)"
if [[ -n "$pid" ]]; then
    uptime="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ' || echo 0)"
fi
case "$uptime" in ''|*[!0-9]*) uptime=0 ;; esac

stats="{\"hs\":$(json_number_array "${rates[@]}"),\"hs_units\":\"hs\",\"temp\":$(json_number_array "${temps[@]}"),\"fan\":$(json_number_array "${fans[@]}"),\"uptime\":$uptime,\"ver\":\"$CUSTOM_VERSION\",\"ar\":[$accepted,$rejected],\"algo\":\"cuckaroo29\",\"bus_numbers\":$(json_number_array "${buses[@]}")}"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf '%s\n' "$stats"
fi
