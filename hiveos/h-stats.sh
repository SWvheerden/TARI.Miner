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
        # Only a whole line in the miner's own report format counts. Pool text
        # is always logged after a prefix such as "pool error:", so it cannot
        # forge one. Fields are read by position; later key=number fields after
        # t= are allowed. Over-long numbers are ignored, and a report older than
        # 90 s means the miner has stopped reporting, so the rate drops to 0.
        read -r rate gpu_accepted gpu_rejected < <(LC_ALL=C awk -v now="$now" '
            /^speed [0-9]+\.[0-9]+ g\/s \| avg [0-9]+\.[0-9]+ g\/s \| graphs=[0-9]+ cycles=[0-9]+ submitted=[0-9]+ accepted=[0-9]+ rejected=[0-9]+ t=[0-9]+( [a-z_]+=[0-9]+)*$/ {
                a = substr($12, 10)
                r = substr($13, 10)
                t = substr($14, 3)
                if (length($2) > 12 || length(a) > 15 || length(r) > 15 || length(t) > 12) next
                rate = $2
                accepted = a
                rejected = r
                seen = t
            }
            END {
                if (seen == "" || now - seen > 90) rate = 0
                printf "%.3f %.0f %.0f\n", rate + 0, accepted + 0, rejected + 0
            }
        ' "$log_file")
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
