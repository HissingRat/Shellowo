sh -s <<'SHELLOW_STATUS'
set +e

SAMPLE_SEC=0.5
SAMPLE_MS=500

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/ /g'
}

detect_platform() {
    if [ -r /system/build.prop ] || command -v getprop >/dev/null 2>&1; then
        printf android
    else
        printf linux
    fi
}

read_cpu() {
    awk '/^cpu / {
        idle=$5+$6
        total=0
        for (i=2; i<=NF; i++) total += $i
        printf "%s %s\n", total, idle
        exit
    }' /proc/stat 2>/dev/null
}

read_net() {
    awk -F'[: ]+' '
        NR > 2 && $2 != "lo" {
            rx += $3
            tx += $11
        }
        END { printf "%.0f %.0f\n", rx, tx }
    ' /proc/net/dev 2>/dev/null
}

mem_json() {
    awk '
        /^MemTotal:/ { mt=$2 * 1024 }
        /^MemAvailable:/ { ma=$2 * 1024 }
        /^MemFree:/ { mf=$2 * 1024 }
        /^Buffers:/ { bf=$2 * 1024 }
        /^Cached:/ { ca=$2 * 1024 }
        /^SwapTotal:/ { st=$2 * 1024 }
        /^SwapFree:/ { sf=$2 * 1024 }
        END {
            if (ma == 0) ma = mf + bf + ca
            mu = mt - ma; if (mu < 0) mu = 0
            su = st - sf; if (su < 0) su = 0
            mp = mt > 0 ? mu * 100.0 / mt : 0
            sp = st > 0 ? su * 100.0 / st : 0
            printf "\"memory\":{\"used_bytes\":%.0f,\"total_bytes\":%.0f,\"percent\":%.1f},", mu, mt, mp
            printf "\"swap\":{\"used_bytes\":%.0f,\"total_bytes\":%.0f,\"percent\":%.1f}", su, st, sp
        }
    ' /proc/meminfo 2>/dev/null || \
    printf '"memory":{"used_bytes":0,"total_bytes":0,"percent":0.0},"swap":{"used_bytes":0,"total_bytes":0,"percent":0.0}'
}

disk_json() {
    if df -P -B1 >/dev/null 2>&1; then
        df -P -B1 2>/dev/null
    else
        df -P 2>/dev/null
    fi | awk '
        NR > 1 && count < 6 {
            path=$6
            if (path == "") path=$NF
            if (path ~ /^\/proc/ || path ~ /^\/sys/ || path ~ /^\/dev\/pts/) next

            total=$2
            used=$3
            free=$4

            # toybox/coreutils without -B1 usually returns 1K blocks
            if (total < 100000000) {
                total *= 1024
                used *= 1024
                free *= 1024
            }

            percent = total > 0 ? used * 100.0 / total : 0
            gsub(/\\/,"\\\\",path)
            gsub(/"/,"\\\"",path)

            if (count > 0) printf ","
            printf "{\"path\":\"%s\",\"free_bytes\":%.0f,\"total_bytes\":%.0f,\"percent\":%.1f}", path, free, total, percent
            count++
        }
    '
}

process_json() {
    # GNU/procps ps
    if ps -eo pcpu,rss,comm --sort=-pcpu >/dev/null 2>&1; then
        ps -eo pcpu,rss,comm --sort=-pcpu 2>/dev/null | awk '
            NR > 1 && count < 5 {
                cmd=$3
                gsub(/\\/,"\\\\",cmd)
                gsub(/"/,"\\\"",cmd)
                if (count > 0) printf ","
                printf "{\"cpu_percent\":%.1f,\"memory_bytes\":%.0f,\"command\":\"%s\"}", $1, $2 * 1024, cmd
                count++
            }
        '
        return
    fi

    # Android toybox ps fallback
    ps -A -o PID,NAME,RSS 2>/dev/null | awk '
        NR > 1 && count < 5 {
            pid=$1
            cmd=$2
            rss=$3

            if (rss == "" || rss !~ /^[0-9]+$/) rss=0

            gsub(/\\/,"\\\\",cmd)
            gsub(/"/,"\\\"",cmd)

            if (count > 0) printf ","
            printf "{\"cpu_percent\":0.0,\"memory_bytes\":%.0f,\"command\":\"%s\"}", rss * 1024, cmd
            count++
        }
    '
}

platform=$(detect_platform)

ip_value=$(
    { hostname -I 2>/dev/null || ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || hostname 2>/dev/null; } |
    awk '{ print $1; exit }'
)
ip_value=${ip_value:-unknown}
ip_json=$(json_escape "$ip_value")

uptime_seconds=$(
    awk '{ printf "%.0f\n", $1; exit }' /proc/uptime 2>/dev/null
)
uptime_seconds=${uptime_seconds:-0}

cpu_a=$(read_cpu)
net_a=$(read_net)
sleep "$SAMPLE_SEC"
cpu_b=$(read_cpu)
net_b=$(read_net)

set -- $cpu_a
cpu_total_a=${1:-0}
cpu_idle_a=${2:-0}
set -- $cpu_b
cpu_total_b=${1:-0}
cpu_idle_b=${2:-0}

cpu_percent=$(
    awk -v ta="$cpu_total_a" -v ia="$cpu_idle_a" -v tb="$cpu_total_b" -v ib="$cpu_idle_b" 'BEGIN {
        td = tb - ta
        id = ib - ia
        pct = td > 0 ? (td - id) * 100.0 / td : 0
        if (pct < 0) pct = 0
        if (pct > 100) pct = 100
        printf "%.1f", pct
    }'
)

set -- $net_a
net_rx_a=${1:-0}
net_tx_a=${2:-0}
set -- $net_b
net_rx_b=${1:-0}
net_tx_b=${2:-0}

net_json=$(
    awk -v rxa="$net_rx_a" -v txa="$net_tx_a" -v rxb="$net_rx_b" -v txb="$net_tx_b" -v s="$SAMPLE_SEC" 'BEGIN {
        rx = int((rxb - rxa) / s)
        tx = int((txb - txa) / s)
        if (rx < 0) rx = 0
        if (tx < 0) tx = 0
        printf "\"network\":{\"rx_bytes_per_sec\":%d,\"tx_bytes_per_sec\":%d}", rx, tx
    }'
)

printf '{'
printf '"schema":"shellow.status.v1",'
printf '"platform":"%s",' "$platform"
printf '"sample_ms":%s,' "$SAMPLE_MS"
printf '"ip":"%s",' "$ip_json"
printf '"uptime_seconds":%s,' "$uptime_seconds"
printf '"cpu":{"percent":%s},' "$cpu_percent"
mem_json
printf ',%s,' "$net_json"
printf '"disks":['
disk_json
printf '],"processes":['
process_json
printf ']}'
printf '\n'
SHELLOW_STATUS
