#!/bin/bash
# relay.sh — Warp Relay v7.0 — UDP relay hub (kernel DNAT) with watchdog + TUI
# https://github.com/BlackSysShark25/warp-relay   (MIT)
#
# Turns a VPS into a transparent UDP relay: clients connect to <relay-ip>:<port>,
# the kernel forwards the stream to the real VPN server (WireGuard, AmneziaWG,
# Cloudflare WARP, Hysteria, ...) with DNAT + MASQUERADE. No userspace proxy,
# no extra latency, hostnames are re-resolved automatically.
#
# USAGE:
#   sudo ./relay.sh          — First-time setup wizard, then management TUI
#   sudo relay               — Management TUI directly (after install)
#   sudo ./relay.sh --setup  — Force re-run setup
#   relay.sh --version | --help

set -uo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────
VERSION="7.0"
TAG="WR_RULE"
WR_CLIENT_TAG="WR_CLIENT"
CONFIG_DIR="/etc/warp-relay"
CONFIG_FILE="${CONFIG_DIR}/mappings.conf"
SYSCTL_FILE="/etc/sysctl.d/90-warp-relay.conf"
MODULES_FILE="/etc/modules-load.d/warp-relay-conntrack.conf"
APPLY_SCRIPT="/usr/local/bin/warp-relay-apply"
WATCHDOG_SCRIPT="/usr/local/bin/warp-relay-watchdog"
APPLY_SERVICE="/etc/systemd/system/warp-relay-apply.service"
WATCHDOG_SERVICE="/etc/systemd/system/warp-relay-watchdog.service"
REAPPLY_SERVICE="/etc/systemd/system/warp-relay-sysctl-reapply.service"
RELAY_BIN="/usr/local/bin/relay"
LOG_FILE="/var/log/warp-relay.log"
WATCHDOG_INTERVAL=25
STALL_TIMEOUT=75
REFRESH_LIVE=10
# Cloudflare WARP preset: clients talk to relay:4500, the WireGuard data port of
# WARP is 2408 (4500→4500 was a long-standing bug: WARP never answered there).
WARP_HOST="engage.cloudflareclient.com"
WARP_SRC_PORT=4500
WARP_DST_PORT=2408

# ── Mode detection ─────────────────────────────────────────────────────────────
# relay.sh  → setup mode    |    relay (no .sh) → TUI mode
case "${1:-}" in
    -v|--version) echo "Warp Relay v${VERSION}"; exit 0 ;;
    -h|--help)
        sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
esac
SCRIPT_SELF="$(realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_BASENAME="$(basename "$0")"
SCRIPT_MODE="tui"
[[ "$SCRIPT_BASENAME" == *.sh || "${1:-}" == "--setup" ]] && SCRIPT_MODE="setup"

# ── Colors ─────────────────────────────────────────────────────────────────────
Z0=$'\033[0m'
ZB=$'\033[1m'
ZD=$'\033[38;5;242m'
ZW=$'\033[38;5;255m'
ZY=$'\033[38;5;220m'
ZG=$'\033[38;5;83m'
ZR=$'\033[38;5;203m'
ZC=$'\033[38;5;81m'
# shellcheck disable=SC2034  # palette entry kept for custom screens
ZM=$'\033[38;5;177m'
ZBL=$'\033[38;5;24m'
ZT=$'\033[38;5;43m'
ZS=$'\033[38;5;236m'

# Legacy colors for setup output (echo -e compatible)
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'
W='\033[1;37m'; DIM='\033[2m'; BOLD='\033[1m'; RESET='\033[0m'

# ── Global state ──────────────────────────────────────────────────────────────
declare -gA DNS_CACHE=()
DNS_CACHE_TS=0
PREV_CPU_TOTAL=0
PREV_CPU_IDLE=0
NET_IFACE=""
COLS=120
ROWS=40
IPTABLES_BACKEND_SWITCHED=0

# ── Terminal ──────────────────────────────────────────────────────────────────
init_term() {
    NET_IFACE=$(ip route show default 2>/dev/null | awk 'NR==1{print $5}')
    if [[ -z "$NET_IFACE" ]]; then
        local _d
        for _d in /sys/class/net/*; do
            [[ "$(basename "$_d")" == "lo" ]] && continue
            NET_IFACE="$(basename "$_d")"; break
        done
    fi
    tput smcup 2>/dev/null
    tput civis 2>/dev/null
    trap '_on_exit' EXIT INT TERM
}

_on_exit() { tput rmcup 2>/dev/null; tput cnorm 2>/dev/null; exit 0; }
# shellcheck disable=SC2034  # ROWS is kept for screens that need the height
term_size() { COLS=$(tput cols 2>/dev/null || echo 120); ROWS=$(tput lines 2>/dev/null || echo 40); }
cursor_show() { tput cnorm 2>/dev/null; stty echo 2>/dev/null || true; }
cursor_hide() { tput civis 2>/dev/null; }

# ── Setup helpers (echo-based, for non-TUI output) ────────────────────────────
info()  { echo -e "  ${G}✓${RESET}  $*"; }
warn()  { echo -e "  ${Y}⚠${RESET}  $*"; }
err()   { echo -e "  ${R}✗${RESET}  $*" >&2; }
die()   { err "$*"; exit 1; }
blank() { echo ""; }
hr()    { echo -e "  ${DIM}$(printf '─%.0s' {1..68})${RESET}"; }
section_header() { blank; echo -e "  ${BOLD}${C}▶  $*${RESET}"; hr; blank; }

# ── System metrics ─────────────────────────────────────────────────────────────
fmt_bytes() {
    local b="${1:-0}"
    if   (( b < 1024 ));       then printf "%d B"       "$b"
    elif (( b < 1048576 ));    then awk -v n="$b" 'BEGIN{printf "%.1f KB",n/1024}'
    elif (( b < 1073741824 )); then awk -v n="$b" 'BEGIN{printf "%.1f MB",n/1048576}'
    else                            awk -v n="$b" 'BEGIN{printf "%.2f GB",n/1073741824}'; fi
}

pbar() {
    local pct=${1:-0} w=${2:-12} filled i on="" off=""
    (( pct > 100 )) && pct=100
    filled=$(( pct * w / 100 ))
    for (( i=0; i<filled; i++ )); do on+="█"; done
    for (( i=filled; i<w;  i++ )); do off+="░"; done
    if   (( pct < 60 )); then printf "${ZG}%s${ZS}%s${Z0}" "$on" "$off"
    elif (( pct < 80 )); then printf "${ZY}%s${ZS}%s${Z0}" "$on" "$off"
    else                      printf "${ZR}%s${ZS}%s${Z0}" "$on" "$off"; fi
}

get_cpu_pct() {
    local -a f; read -ra f < /proc/stat
    local total=0 idle=${f[4]} v
    for v in "${f[@]:1}"; do (( total += v )); done
    local dt=$(( total - PREV_CPU_TOTAL )) di=$(( idle - PREV_CPU_IDLE ))
    PREV_CPU_TOTAL=$total; PREV_CPU_IDLE=$idle
    (( dt > 0 )) && echo $(( (dt - di) * 100 / dt )) || echo 0
}

get_mem() {
    local mt=0 ma=0 st=0 sf=0
    while read -r k v _; do
        case "${k%:}" in
            MemTotal)     mt=$v ;; MemAvailable) ma=$v ;;
            SwapTotal)    st=$v ;; SwapFree)     sf=$v ;;
        esac
    done < /proc/meminfo
    local ru=$(( mt - ma )) su=$(( st - sf ))
    local rp=0 sp=0
    (( mt > 0 )) && rp=$(( ru * 100 / mt ))
    (( st > 0 )) && sp=$(( su * 100 / st ))
    echo "$ru $mt $rp $su $st $sp"
}

get_disk() {
    read -r _ sz us _ pstr _ < <(df -k / 2>/dev/null | tail -1)
    echo "${sz:-0} ${us:-0} ${pstr//%/}"
}

get_net_total() {
    [[ -z "$NET_IFACE" ]] && echo "0 0" && return
    local rx tx
    rx=$(awk -v i="${NET_IFACE}:" '$1==i{print $2}'  /proc/net/dev 2>/dev/null); rx=${rx:-0}
    tx=$(awk -v i="${NET_IFACE}:" '$1==i{print $10}' /proc/net/dev 2>/dev/null); tx=${tx:-0}
    echo "$rx $tx"
}

get_os() {
    [[ -f /etc/os-release ]] \
        && ( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}" ) \
        || echo "Linux"
}

get_uptime_str() {
    local since start now diff d h m
    since=$(systemctl show warp-relay-watchdog \
            --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2)
    [[ -z "$since" || "$since" == "n/a" ]] && echo "—" && return
    start=$(date -d "$since" +%s 2>/dev/null) || { echo "—"; return; }
    now=$(date +%s); diff=$(( now - start ))
    d=$(( diff/86400 )); h=$(( diff%86400/3600 )); m=$(( diff%3600/60 ))
    [[ $d -gt 0 ]] && echo "${d}d ${h}h ${m}m" && return
    [[ $h -gt 0 ]] && echo "${h}h ${m}m" && return
    echo "${m}m"
}

# ── DNS (cached 60s) ──────────────────────────────────────────────────────────
resolve_host() {
    local host="$1" now ip
    # Fast path for IPs
    [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$host" && return
    now=$(date +%s)
    if [[ -n "${DNS_CACHE[$host]:-}" && $(( now - DNS_CACHE_TS )) -lt 60 ]]; then
        echo "${DNS_CACHE[$host]}"; return
    fi
    ip=$(getent ahosts "$host" 2>/dev/null | awk '/STREAM/{print $1; exit}')
    [[ -z "$ip" ]] && \
        ip=$(python3 -c "import socket; print(socket.gethostbyname('$host'))" 2>/dev/null)
    [[ -z "$ip" ]] && ip="?"
    DNS_CACHE[$host]="$ip"
    DNS_CACHE_TS=$now
    echo "$ip"
}

detect_public_ip() {
    curl -4s --connect-timeout 5 ifconfig.me 2>/dev/null \
    || curl -4s --connect-timeout 5 icanhazip.com 2>/dev/null \
    || hostname -I | awk '{print $1}'
}

log_msg() {
    echo "$(date '+%F %T') $*" >> "$LOG_FILE" 2>/dev/null || true
    logger -t warp-relay "$*" 2>/dev/null || true
}

# ── Config ─────────────────────────────────────────────────────────────────────
read_mappings() {
    [[ -f "$CONFIG_FILE" ]] || return
    grep -v '^\s*#' "$CONFIG_FILE" | grep -v '^\s*$' || true
}

count_mappings() { read_mappings | wc -l; }

parse_mapping() {
    # shellcheck disable=SC2034  # M_SRC_IP is informational (rules match any LOCAL address)
    read -r M_SRC_IP M_SRC_PORT M_DST_HOST M_DST_PORT M_LABEL <<< "$1"
    M_LABEL="${M_LABEL:-$M_DST_HOST}"
}

port_in_use() { read_mappings | awk '{print $2}' | grep -q "^${1}$"; }

# ── iptables-legacy ────────────────────────────────────────────────────────────
ensure_iptables_legacy() {
    # Backend-agnostic — do NOT switch to legacy. The relay's DNAT/MASQUERADE/FORWARD
    # work on the modern nft backend; force-switching split rules from nft-based tproxy/AWG/mesh and
    # broke firewalls. Just report the current backend and keep it.
    local current
    current=$(update-alternatives --get-selections 2>/dev/null \
              | awk '/^iptables[[:space:]]/{print $NF}')
    [[ "$SCRIPT_MODE" == "setup" ]] && \
        echo -e "  ${G}✓${RESET}  iptables backend: ${G}${current:-default}${RESET} (kept as-is — backend-agnostic)"
    return 0
}

apply_sysctl() {
    # v7: make nf_conntrack load BEFORE systemd-sysctl. Otherwise the
    # net.netfilter.* keys do not exist yet at boot, systemd-sysctl silently
    # skips them ("Couldn't write ... No such file or directory") and the module
    # later comes up with the kernel defaults (udp 30s / stream 120s) — UDP
    # sessions through the relay then die every 30 s of silence until someone
    # runs `sysctl --system` by hand. Symptom to check on an installed node:
    #   journalctl -b -u systemd-sysctl | grep "Couldn't write"
    echo "nf_conntrack" > "$MODULES_FILE"
    modprobe nf_conntrack 2>/dev/null || true
    cat > "$SYSCTL_FILE" << 'EOF'
net.ipv4.ip_forward=1
net.netfilter.nf_conntrack_max=262144
net.netfilter.nf_conntrack_udp_timeout=120
net.netfilter.nf_conntrack_udp_timeout_stream=180
net.netfilter.nf_conntrack_acct=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
    sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
}

save_rules() {
    mkdir -p "$(dirname /etc/iptables/rules.v4)"
    netfilter-persistent save >/dev/null 2>&1 || true
}

init_config() {
    mkdir -p "$CONFIG_DIR"
    touch "$LOG_FILE"
    [[ -f "$CONFIG_FILE" ]] || cat > "$CONFIG_FILE" << 'CONF'
# Warp Relay — port mappings
# Format: SRC_IP  SRC_PORT  DST_HOST_OR_IP  DST_PORT  LABEL
# SRC_IP is informational (rules match any LOCAL address of this node).
# DST_HOST may be a hostname: it is re-resolved on every apply and by the watchdog.
# Examples:
#   0.0.0.0  51820  wg.example.com               51820  wg-germany
#   0.0.0.0  4500   engage.cloudflareclient.com  2408   cloudflare-warp
CONF
}

# ── iptables rules ─────────────────────────────────────────────────────────────
# v2.1: rule_exists checks LOCAL-guard + tag (indication for TUI; strict DST check
# done inside apply_one/rule_ok). Old dport-only match returned true even for stale
# WR_RULE with wrong DST (the pashaTR mine).
rule_exists() {
    iptables -t nat -S PREROUTING 2>/dev/null \
        | grep -q -- "--dport ${1}.*addrtype --dst-type LOCAL .*${TAG}\|${TAG}.*addrtype --dst-type LOCAL .*--dport ${1}"
}

apply_one() {
    local src_port="$1" dst_ip="$2" dst_port="$3"
    remove_one_rules "$src_port" "$dst_ip" "$dst_port" 2>/dev/null || true
    # v2.1: PREROUTING guarded by `-m addrtype --dst-type LOCAL` so DNAT fires only
    # for packets addressed to a LOCAL IP of THIS node — does NOT hijack transit
    # UDP:src_port traffic of clients (e.g. IPsec/AWG rekey to some 3rd party :4500).
    iptables -t nat -A PREROUTING \
        -p udp -m addrtype --dst-type LOCAL --dport "$src_port" -m comment --comment "$TAG" \
        -j DNAT --to-destination "${dst_ip}:${dst_port}"
    iptables -t nat -A POSTROUTING \
        -p udp -d "$dst_ip" --dport "$dst_port" \
        -m comment --comment "$TAG" -j MASQUERADE --random-fully
    iptables -A FORWARD \
        -p udp -d "$dst_ip" --dport "$dst_port" \
        -m comment --comment "$TAG" -j ACCEPT
    iptables -A FORWARD \
        -p udp -s "$dst_ip" --sport "$dst_port" \
        -m comment --comment "$TAG" -j ACCEPT
}

remove_one_rules() {
    local port="$1" dst_ip="${2:-}" dst_port="${3:-}" rule
    while IFS= read -r rule; do
        rule="${rule#-A PREROUTING }"
        iptables -t nat -D PREROUTING $rule 2>/dev/null || true
    done < <(iptables -t nat -S PREROUTING 2>/dev/null \
              | grep "${TAG}" | grep -w "\-\-dport ${port}" || true)
    while IFS= read -r rule; do
        rule="${rule#-A POSTROUTING }"
        iptables -t nat -D POSTROUTING $rule 2>/dev/null || true
    done < <(iptables -t nat -S POSTROUTING 2>/dev/null \
              | grep "${TAG}" \
              | { [[ -n "$dst_ip" ]] && grep -F "$dst_ip" || cat; } \
              | { [[ -n "$dst_port" ]] && grep -w -- "--dport ${dst_port}" || cat; } || true)
    while IFS= read -r rule; do
        rule="${rule#-A FORWARD }"
        iptables -D FORWARD $rule 2>/dev/null || true
    done < <(iptables -S FORWARD 2>/dev/null \
              | grep "${TAG}" \
              | { [[ -n "$dst_ip" ]] && grep -F "$dst_ip" || cat; } \
              | { [[ -n "$dst_port" ]] && grep -E -- "(--dport ${dst_port}|--sport ${dst_port})" || cat; } || true)
}

apply_all() {
    sysctl -w net.netfilter.nf_conntrack_acct=1 >/dev/null 2>&1 || true
    flush_all_rules >/dev/null 2>&1 || true
    local cnt=0
    while IFS= read -r line; do
        parse_mapping "$line"
        local dst_ip; dst_ip=$(resolve_host "$M_DST_HOST")
        [[ "$dst_ip" == "?" ]] && continue
        apply_one "$M_SRC_PORT" "$dst_ip" "$M_DST_PORT"
        log_msg "applied: :$M_SRC_PORT → ${M_DST_HOST}:$M_DST_PORT ($dst_ip)"
        (( cnt++ )) || true
    done < <(read_mappings)
    save_rules
    echo "$cnt"
}

flush_all_rules() {
    local rule
    while IFS= read -r rule; do
        rule="${rule#-A PREROUTING }"
        iptables -t nat -D PREROUTING $rule 2>/dev/null || true
    done < <(iptables -t nat -S PREROUTING 2>/dev/null | grep "$TAG" || true)
    while IFS= read -r rule; do
        rule="${rule#-A POSTROUTING }"
        iptables -t nat -D POSTROUTING $rule 2>/dev/null || true
    done < <(iptables -t nat -S POSTROUTING 2>/dev/null | grep "$TAG" || true)
    while IFS= read -r rule; do
        rule="${rule#-A FORWARD }"
        iptables -D FORWARD $rule 2>/dev/null || true
    done < <(iptables -S FORWARD 2>/dev/null | grep -E "$TAG|WR_CLIENT" || true)
    save_rules
}

flush_conntrack_for() {
    conntrack -D -d "$1" >/dev/null 2>&1 || true
    conntrack -D -s "$1" >/dev/null 2>&1 || true
}

# ── Client tracking ────────────────────────────────────────────────────────────
get_clients() {
    local port="$1" raw ips tag fwd_table
    raw=$(conntrack -L -p udp --dport "$port" 2>/dev/null) || true
    [[ -z "$raw" ]] && return
    ips=$(echo "$raw" | awk '{print $4}' | cut -d= -f2 \
        | grep -Ev '^$|^10\.|^127\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[01])\.' \
        | sort -u | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n) || true
    [[ -z "$ips" ]] && return
    tag="${WR_CLIENT_TAG}_${port}"
    local ip
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        if ! iptables -C FORWARD -s "$ip" -m comment --comment "$tag" \
                -j ACCEPT 2>/dev/null; then
            iptables -I FORWARD -s "$ip" -m comment --comment "$tag" \
                -j ACCEPT 2>/dev/null || true
            iptables -I FORWARD -d "$ip" -m comment --comment "$tag" \
                -j ACCEPT 2>/dev/null || true
        fi
    done <<< "$ips"
    fwd_table=$(iptables -L FORWARD -v -n -x 2>/dev/null) || true
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        local tx rx
        tx=$(echo "$fwd_table" | awk -v ip="$ip" -v t="$tag" \
            '$0~t && $8==ip {s+=$2} END{print s+0}')
        rx=$(echo "$fwd_table" | awk -v ip="$ip" -v t="$tag" \
            '$0~t && $9==ip {s+=$2} END{print s+0}')
        printf '%s %d %d\n' "$ip" "${tx:-0}" "${rx:-0}"
    done <<< "$ips"
}

geolocate_batch() {
    curl -s --max-time 8 -X POST \
        "http://ip-api.com/batch?fields=query,country,city,isp" \
        -H "Content-Type: application/json" -d "$1" 2>/dev/null
}

# ── Write service scripts ──────────────────────────────────────────────────────
write_apply_script() {
    cat > "$APPLY_SCRIPT" << 'APPLYEOF'
#!/bin/bash
# warp-relay-apply (Warp Relay v7 — replace-aware + LOCAL guard + exact-match):
#   - backend-agnostic, netmax-conntrack (120/180), MASQUERADE --random-fully
#   - rule_ok verifies EXACT dport+DST+LOCAL-guard; stale WR_RULE on same dport with different
#     --to-destination or missing LOCAL match is auto-flushed before rebuild
#   - PREROUTING DNAT is guarded by `-m addrtype --dst-type LOCAL` so it fires only on packets
#     addressed to a LOCAL IP of THIS node (does NOT touch transit UDP:sp traffic of clients)
# Modes:
#   warp-relay-apply           — normal (idempotent, patch-only stale)
#   warp-relay-apply --replace — force: flush ALL WR_RULE, rebuild from mappings.conf
set -uo pipefail
TAG="WR_RULE"
CONFIG_FILE="/etc/warp-relay/mappings.conf"
LOG_FILE="/var/log/warp-relay.log"
SYSCTL_FILE="/etc/sysctl.d/90-warp-relay.conf"
MODE="${1:-normal}"

log() { echo "$(date '+%F %T') [apply] $*" >> "$LOG_FILE" 2>/dev/null; logger -t warp-relay-apply "$*" 2>/dev/null || true; }

# Backend-agnostic: do NOT switch the iptables backend (coexists with nft-based tproxy/AWG/mesh rules).
resolve() {
    local h="$1"
    [[ "$h" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$h" && return
    getent ahosts "$h" 2>/dev/null | awk '/STREAM/{print $1;exit}'
}
rule_ok() {
    # v7: exact match via `iptables -C` instead of grep over `-S` output. The grep
    # variant never matched the real rule text, so every run appended one more
    # copy of the same rule.
    local sp="$1" dip="$2" dp="$3"
    iptables -w 10 -t nat -C PREROUTING -p udp -m addrtype --dst-type LOCAL --dport "$sp" -m comment --comment "$TAG" -j DNAT --to-destination "${dip}:${dp}" 2>/dev/null
}
flush_stale_wr() {
    local sp="$1" dip="$2" dp="$3" rule
    while IFS= read -r rule; do
        [[ -z "$rule" ]] && continue
        rule="${rule#-A PREROUTING }"
        iptables -t nat -D PREROUTING $rule 2>/dev/null && log "flushed stale WR_RULE (:$sp, wrong DST or missing LOCAL guard): $rule"
    done < <(iptables -t nat -S PREROUTING 2>/dev/null | grep -- "$TAG" | grep -w -- "--dport $sp" | grep -v -- "addrtype --dst-type LOCAL.*--to-destination ${dip}:${dp}" || true)
}
flush_all_wr() {
    local rule
    while IFS= read -r rule; do rule="${rule#-A PREROUTING }";  iptables -t nat -D PREROUTING  $rule 2>/dev/null || true; done < <(iptables -t nat -S PREROUTING  2>/dev/null | grep -- "$TAG" || true)
    while IFS= read -r rule; do rule="${rule#-A POSTROUTING }"; iptables -t nat -D POSTROUTING $rule 2>/dev/null || true; done < <(iptables -t nat -S POSTROUTING 2>/dev/null | grep -- "$TAG" || true)
    while IFS= read -r rule; do rule="${rule#-A FORWARD }";     iptables -D FORWARD $rule 2>/dev/null || true; done < <(iptables -S FORWARD 2>/dev/null | grep -- "$TAG" || true)
    log "flush_all_wr: cleared all WR_RULE"
}

# Sysctl — forwarding + conntrack 120/180 (NEVER the kernel default 30 s: it kills idle UDP sessions).
# nf_conntrack is loaded first so the net.netfilter.* keys exist (see apply_sysctl in relay.sh).
modprobe nf_conntrack 2>/dev/null || true
cat > "$SYSCTL_FILE" << 'SEOF'
net.ipv4.ip_forward=1
net.netfilter.nf_conntrack_max=262144
net.netfilter.nf_conntrack_udp_timeout=120
net.netfilter.nf_conntrack_udp_timeout_stream=180
net.netfilter.nf_conntrack_acct=1
SEOF
sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

[[ ! -f "$CONFIG_FILE" ]] && { log "no config"; exit 0; }
if [[ "$MODE" == "--replace" || "$MODE" == "-r" ]]; then flush_all_wr; fi
grep -v '^\s*#' "$CONFIG_FILE" | grep -v '^\s*$' | while read -r _ sp dh dp _lbl; do
    [[ -z "${sp:-}" || -z "${dp:-}" ]] && continue
    dip=$(resolve "$dh"); [[ -z "$dip" ]] && { log "cannot resolve $dh"; continue; }
    rule_ok "$sp" "$dip" "$dp" && continue
    flush_stale_wr "$sp" "$dip" "$dp"
    # every rule is check-then-add (-C || -A): re-running apply never duplicates rules
    iptables -w 10 -t nat -C PREROUTING -p udp -m addrtype --dst-type LOCAL --dport "$sp" -m comment --comment "$TAG" -j DNAT --to-destination "${dip}:${dp}" 2>/dev/null || \
    iptables -w 10 -t nat -A PREROUTING -p udp -m addrtype --dst-type LOCAL --dport "$sp" -m comment --comment "$TAG" -j DNAT --to-destination "${dip}:${dp}"
    iptables -w 10 -t nat -C POSTROUTING -p udp -d "$dip" --dport "$dp" -m comment --comment "$TAG" -j MASQUERADE --random-fully 2>/dev/null || \
    iptables -w 10 -t nat -A POSTROUTING -p udp -d "$dip" --dport "$dp" -m comment --comment "$TAG" -j MASQUERADE --random-fully
    iptables -w 10 -C FORWARD -p udp -d "$dip" --dport "$dp" -m comment --comment "$TAG" -j ACCEPT 2>/dev/null || \
    iptables -w 10 -A FORWARD -p udp -d "$dip" --dport "$dp" -m comment --comment "$TAG" -j ACCEPT
    iptables -w 10 -C FORWARD -p udp -s "$dip" --sport "$dp" -m comment --comment "$TAG" -j ACCEPT 2>/dev/null || \
    iptables -w 10 -A FORWARD -p udp -s "$dip" --sport "$dp" -m comment --comment "$TAG" -j ACCEPT
    log "applied :$sp → $dh:$dp ($dip) [LOCAL-guarded]"
done
netfilter-persistent save >/dev/null 2>&1 || true
log "apply done (v7: backend-agnostic, conntrack 120/180, random-fully, replace-aware, LOCAL-guarded, exact-match)"
APPLYEOF
    chmod +x "$APPLY_SCRIPT"
}

write_watchdog_script() {
    cat > "$WATCHDOG_SCRIPT" << WDEOF
#!/bin/bash
set -uo pipefail
TAG="${TAG}"
CONFIG_FILE="${CONFIG_FILE}"
LOG_FILE="${LOG_FILE}"
APPLY_SCRIPT="${APPLY_SCRIPT}"
INTERVAL=${WATCHDOG_INTERVAL}
STALL_TIMEOUT=${STALL_TIMEOUT}

log() { echo "\$(date '+%F %T') [watchdog] \$*" >> "\$LOG_FILE" 2>/dev/null; logger -t warp-relay-watchdog "\$*" 2>/dev/null || true; }

# Backend-agnostic — the watchdog does NOT switch the iptables backend.
resolve() {
    local h="\$1"
    [[ "\$h" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\$ ]] && echo "\$h" && return
    getent ahosts "\$h" 2>/dev/null | awk '/STREAM/{print \$1;exit}'
}
rule_ok() { iptables -t nat -S PREROUTING 2>/dev/null | grep -q -- "--dport \$1.*\${TAG}\|\${TAG}.*--dport \$1"; }
get_bytes() { iptables -L FORWARD -v -n -x 2>/dev/null | awk -v ip="\$1" -v p="\$2" '\$0~ip&&\$0~p{s+=\$2} END{print s+0}'; }
flush_ct() { conntrack -D -d "\$1" >/dev/null 2>&1 || true; conntrack -D -s "\$1" >/dev/null 2>&1 || true; }

declare -A prev_bytes=()
declare -A stall_since=()
declare -A seen_move=()
log "started (interval=\${INTERVAL}s stall_timeout=\${STALL_TIMEOUT}s)"

while true; do
    sleep "\$INTERVAL"
    [[ ! -f "\$CONFIG_FILE" ]] && continue
    while IFS= read -r line; do
        [[ -z "\$line" ]] && continue
        read -r _ sp dh dp _lbl <<< "\$line"
        [[ -z "\$sp" ]] && continue
        dip=\$(resolve "\$dh") || true
        [[ -z "\$dip" ]] && continue
        key="\${sp}_\${dp}"
        if ! rule_ok "\$sp"; then
            log "WARN: rule :\${sp} missing, restoring"
            bash "\$APPLY_SCRIPT" 2>/dev/null || true
            unset "prev_bytes[\$key]" "stall_since[\$key]"
            continue
        fi
        cur=\$(get_bytes "\$dip" "\$dp")
        pb="\${prev_bytes[\$key]:-}"
        if [[ -z "\$pb" ]]; then prev_bytes[\$key]="\$cur"; stall_since[\$key]=0; continue; fi
        if [[ "\$cur" -eq "\$pb" ]]; then
            # v7: a counter that has NEVER moved since the watchdog started means the
            # mapping is simply idle — nobody is using it. That is not a stall: no
            # conntrack flush, no log noise. (The old logic produced tens of
            # thousands of false "STALL" lines per day on idle relays.)
            if [[ -z "\${seen_move[\$key]:-}" ]]; then stall_since[\$key]=0; continue; fi
            ss="\${stall_since[\$key]:-0}"
            [[ "\$ss" -eq 0 ]] && stall_since[\$key]=\$(date +%s) || true
            age=\$(( \$(date +%s) - \${stall_since[\$key]} ))
            if [[ "\$age" -ge "\$STALL_TIMEOUT" ]]; then
                log "STALL :\${sp}→\${dip}:\${dp} no traffic \${age}s after activity → flush conntrack"
                flush_ct "\$dip"
                prev_bytes[\$key]="\$cur"; stall_since[\$key]=0; unset "seen_move[\$key]"
            fi
        else
            prev_bytes[\$key]="\$cur"; stall_since[\$key]=0; seen_move[\$key]=1
        fi
    done < <(grep -v '^\s*#' "\$CONFIG_FILE" 2>/dev/null | grep -v '^\s*\$')
done
WDEOF
    chmod +x "$WATCHDOG_SCRIPT"
}

write_services() {
    cat > "$APPLY_SERVICE" << EOF
[Unit]
Description=Warp Relay - Apply iptables Rules
After=network-online.target nss-lookup.target netfilter-persistent.service
Wants=network-online.target
Before=warp-relay-watchdog.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${APPLY_SCRIPT}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    cat > "$WATCHDOG_SERVICE" << EOF
[Unit]
Description=Warp Relay - Watchdog (stall detection + rule recovery)
After=network-online.target warp-relay-apply.service
Wants=network-online.target warp-relay-apply.service

[Service]
Type=simple
ExecStart=${WATCHDOG_SCRIPT}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # v7: belt-and-braces — re-apply our sysctl once the network is up, in case
    # systemd-sysctl ran before nf_conntrack existed (see apply_sysctl).
    cat > "$REAPPLY_SERVICE" << EOF
[Unit]
Description=Warp Relay - re-apply sysctl after boot (conntrack timeouts)
After=network-online.target systemd-modules-load.service
Wants=network-online.target
Before=warp-relay-apply.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/modprobe nf_conntrack
ExecStart=/sbin/sysctl -q -p ${SYSCTL_FILE}

[Install]
WantedBy=multi-user.target
EOF
}

install_all_services() {
    write_apply_script
    write_watchdog_script
    write_services
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now warp-relay-sysctl-reapply >/dev/null 2>&1 || true
    systemctl enable --now warp-relay-apply    >/dev/null 2>&1 || true
    systemctl enable --now warp-relay-watchdog >/dev/null 2>&1 || true
}

uninstall_all_services() {
    systemctl stop    warp-relay-apply warp-relay-watchdog warp-relay-sysctl-reapply 2>/dev/null || true
    systemctl disable warp-relay-apply warp-relay-watchdog warp-relay-sysctl-reapply 2>/dev/null || true
    rm -f "$APPLY_SCRIPT" "$WATCHDOG_SCRIPT" "$APPLY_SERVICE" "$WATCHDOG_SERVICE" \
          "$REAPPLY_SERVICE" "$MODULES_FILE" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
}

install_relay_bin() {
    # Install self as /usr/local/bin/relay
    cp "$SCRIPT_SELF" "$RELAY_BIN"
    chmod +x "$RELAY_BIN"
    log_msg "relay binary installed: $RELAY_BIN"
}

# ══════════════════════════════════════════════════════════════════════════════
# SETUP MODE
# ══════════════════════════════════════════════════════════════════════════════
run_setup() {
    [[ $EUID -ne 0 ]] && die "Root required: sudo ./relay.sh"

    clear
    echo -e "\n  ${BOLD}${C}╔══════════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "  ${BOLD}${C}║${RESET}  ${W}Warp Relay v${VERSION} — Setup Wizard${RESET}                              ${BOLD}${C}║${RESET}"
    echo -e "  ${BOLD}${C}╚══════════════════════════════════════════════════════════════════════╝${RESET}"
    blank

    # 1. Install dependencies
    section_header "Installing dependencies"
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        echo -ne "  ${C}»${RESET} apt update... "
        apt-get update -qq >/dev/null 2>&1 && echo -e "${G}OK${RESET}" || echo -e "${Y}skipped${RESET}"
        echo -ne "  ${C}»${RESET} Installing packages... "
        apt-get install -y -qq \
            iptables curl bc jq conntrack \
            netfilter-persistent iptables-persistent \
            >/dev/null 2>&1 && echo -e "${G}OK${RESET}" || echo -e "${Y}some packages failed — check manually${RESET}"
    else
        warn "Not a Debian/Ubuntu system: install iptables, conntrack, curl, jq yourself"
        warn "and make sure iptables rules are restored at boot (netfilter-persistent or equivalent)"
    fi

    # 2. iptables legacy
    section_header "iptables backend"
    ensure_iptables_legacy

    # 3. sysctl
    section_header "Kernel parameters"
    apply_sysctl
    echo -e "  ${G}✓${RESET}  net.ipv4.ip_forward=1"
    echo -e "  ${G}✓${RESET}  nf_conntrack loaded at boot before sysctl (${MODULES_FILE})"
    echo -e "  ${G}✓${RESET}  conntrack UDP timeouts 120/180 s (kernel default 30 s drops idle tunnels)"
    echo -e "  ${G}✓${RESET}  nf_conntrack_acct=1  (traffic accounting)"

    # 4. Init config
    init_config
    info "Config dir: ${CONFIG_DIR}"

    # 5. Write & install services
    section_header "Systemd services"
    write_apply_script;    info "warp-relay-apply script written"
    write_watchdog_script; info "warp-relay-watchdog script written"
    write_services;        info "systemd unit files written"
    systemctl daemon-reload 2>/dev/null || true

    # 6. Cloudflare WARP auto-setup
    section_header "Cloudflare WARP auto-setup"
    echo -e "  ${W}WARP${RESET} clients connect to relay:${WARP_SRC_PORT}/UDP → ${WARP_HOST}:${WARP_DST_PORT}"
    blank
    read -rp "  Configure WARP relay now? [Y/n]: " yn_warp
    if [[ "${yn_warp,,}" != "n" ]]; then
        setup_warp_mapping
    else
        warn "Skipped. You can add WARP later via Management → WARP Setup"
    fi

    # 7. Add custom mappings
    section_header "Add port mappings"
    echo -e "  ${DIM}Add additional UDP port mappings (WireGuard, etc.)${RESET}"
    blank
    while true; do
        read -rp "  Add a mapping? [y/N]: " yn_map
        [[ "${yn_map,,}" != "y" ]] && break
        setup_add_mapping_interactive
    done

    # 8. Apply rules & start services
    section_header "Applying rules"
    if [[ $(count_mappings) -gt 0 ]]; then
        local cnt; cnt=$(apply_all)
        info "Applied ${cnt} mapping(s) to iptables"
    else
        warn "No mappings configured"
    fi

    # 9. Enable & start services
    section_header "Starting services"
    systemctl enable --now warp-relay-sysctl-reapply 2>/dev/null && info "warp-relay-sysctl-reapply: enabled" || warn "warp-relay-sysctl-reapply issue"
    systemctl enable --now warp-relay-apply    2>/dev/null && info "warp-relay-apply: enabled + started" || warn "warp-relay-apply issue"
    systemctl enable --now warp-relay-watchdog 2>/dev/null && info "warp-relay-watchdog: enabled + started" || warn "warp-relay-watchdog issue"

    # 10. Install relay binary
    section_header "Installing relay command"
    install_relay_bin
    info "Command ${W}relay${RESET} installed → type ${W}relay${RESET} anytime to open management console"

    # 11. If iptables backend was switched — re-apply
    if [[ "$IPTABLES_BACKEND_SWITCHED" -eq 1 ]]; then
        blank; warn "iptables backend was just switched — re-applying all rules..."
        apply_all >/dev/null
        info "Rules re-applied"
    fi

    # Done
    blank
    echo -e "  ${G}${BOLD}╔══════════════════════════════════════╗${RESET}"
    echo -e "  ${G}${BOLD}║  Setup complete! Type: relay         ║${RESET}"
    echo -e "  ${G}${BOLD}╚══════════════════════════════════════╝${RESET}"
    blank
    read -rp "  Open management console now? [Y/n]: " yn_open
    [[ "${yn_open,,}" == "n" ]] && exit 0

    # Launch TUI
    SCRIPT_MODE="tui"
    check_tui_deps
    init_term
    screen_main
}

setup_warp_mapping() {
    local src_ip dst_ip
    echo -ne "  ${C}»${RESET} Detecting relay public IP... "
    src_ip=$(detect_public_ip); echo -e "${W}${src_ip}${RESET}"
    echo -ne "  ${C}»${RESET} Resolving ${WARP_HOST}... "
    dst_ip=$(resolve_host "$WARP_HOST" 2>/dev/null) || dst_ip=""
    if [[ -z "$dst_ip" || "$dst_ip" == "?" ]]; then
        warn "Cannot resolve ${WARP_HOST}"
        return 1
    fi
    echo -e "${W}${dst_ip}${RESET}"
    blank
    if port_in_use "$WARP_SRC_PORT"; then
        warn "Port ${WARP_SRC_PORT} already configured"
        return 0
    fi
    echo -e "  ${W}${src_ip}:${WARP_SRC_PORT}${RESET} ${DIM}→${RESET} ${W}${dst_ip}:${WARP_DST_PORT}${RESET}"
    printf "0.0.0.0 %s %s %s cloudflare-warp\n" "$WARP_SRC_PORT" "$WARP_HOST" "$WARP_DST_PORT" >> "$CONFIG_FILE"
    info "WARP mapping saved"
    log_msg "setup: WARP mapping added :${WARP_SRC_PORT} → ${dst_ip}:${WARP_DST_PORT}"
}

setup_add_mapping_interactive() {
    blank
    local src_ip; src_ip=$(detect_public_ip)
    local src_port
    while true; do
        read -rp "  External UDP port: " src_port
        [[ "$src_port" =~ ^[0-9]+$ ]] || { warn "Enter a number"; continue; }
        port_in_use "$src_port" && { warn "Port $src_port already used"; continue; }
        break
    done
    local dst_host
    while true; do
        read -rp "  Destination host/IP: " dst_host
        [[ -n "$dst_host" ]] && break
        warn "Cannot be empty"
    done
    local dst_port; read -rp "  Destination port [$src_port]: " dst_port
    dst_port="${dst_port:-$src_port}"
    local label; read -rp "  Label (e.g. Germany-WG): " label
    [[ -z "$label" ]] && label="$dst_host"
    echo -ne "  ${C}»${RESET} Resolving ${dst_host}... "
    local dst_ip; dst_ip=$(resolve_host "$dst_host" 2>/dev/null) || dst_ip=""
    [[ -n "$dst_ip" && "$dst_ip" != "?" ]] \
        && echo -e "${G}${dst_ip}${RESET}" \
        || echo -e "${Y}unresolvable (watchdog will retry)${RESET}"
    printf "0.0.0.0 %s %s %s %s\n" "$src_port" "$dst_host" "$dst_port" "$label" >> "$CONFIG_FILE"
    info "Mapping saved: :${src_port} → ${dst_host}:${dst_port} [${label}]"
}

# ── TUI dependencies check ─────────────────────────────────────────────────────
check_tui_deps() {
    [[ $EUID -ne 0 ]] && echo "Need root: sudo relay" && exit 1
    for _dep in jq conntrack curl; do
        command -v "$_dep" >/dev/null 2>&1 || {
            echo "Missing dependency: $_dep"
            echo "Run: sudo apt install jq conntrack curl"
            exit 1
        }
    done
}

# ── TUI: Draw primitives ───────────────────────────────────────────────────────
sep_line() {
    local w="${1:-$COLS}" ch="${2:--}" clr="${3:-}"
    local s; printf -v s '%*s' "$w" ''; s="${s// /$ch}"
    [[ -n "$clr" ]] && printf "%s%s%s" "$clr" "$s" "$Z0" || printf "%s" "$s"
}

draw_box() {
    local title="$1" sub="${2:-}"
    local bi=$(( COLS - 4 ))
    local bsep; printf -v bsep '%*s' "$bi" ''; bsep="${bsep// /═}"
    local tw=$(( bi / 2 - 1 ))
    local sw=$(( bi - tw - 4 ))
    printf "%s%s╔%s╗%s\n"         "$ZBL" "$ZB" "$bsep" "$Z0"
    local bT bS
    printf -v bT "%-*s" "$tw" "$title"
    printf -v bS "%-*s" "$sw" "$sub"
    printf "%s%s║%s  %s%s%s%s  %s%s%s  %s%s║%s\n" \
           "$ZBL" "$ZB" "$Z0"  "$ZB" "$ZW" "$bT" "$Z0" \
           "$ZD" "$bS" "$Z0"  "$ZBL" "$ZB" "$Z0"
    printf "%s%s╚%s╝%s\n"         "$ZBL" "$ZB" "$bsep" "$Z0"
}

draw_sysbar() {
    local os cpu_pct load_avg uptime_str
    local ram_u ram_t ram_p swap_u swap_t swap_p
    local d_sz d_us d_p net_rx net_tx
    local wd_s ap_s fwd_s fwd_v

    os=$(get_os)
    cpu_pct=$(get_cpu_pct)
    load_avg=$(awk '{printf "%.2f  %.2f  %.2f",$1,$2,$3}' /proc/loadavg)
    uptime_str=$(get_uptime_str)

    local mem_out; mem_out=$(get_mem)
    read -r ram_u ram_t ram_p swap_u swap_t swap_p <<< "$mem_out"
    local disk_out; disk_out=$(get_disk)
    read -r d_sz d_us d_p <<< "$disk_out"
    local net_out; net_out=$(get_net_total)
    read -r net_rx net_tx <<< "$net_out"

    local cpu_b; cpu_b=$(pbar "$cpu_pct" 10)
    local ram_b; ram_b=$(pbar "$ram_p"   10)
    local swp_b; swp_b=$(pbar "$swap_p"   6)
    local dsk_b; dsk_b=$(pbar "$d_p"      8)

    local ram_uf; ram_uf=$(fmt_bytes $(( ram_u  * 1024 )))
    local ram_tf; ram_tf=$(fmt_bytes $(( ram_t  * 1024 )))
    local swp_uf; swp_uf=$(fmt_bytes $(( swap_u * 1024 )))
    local swp_tf; swp_tf=$(fmt_bytes $(( swap_t * 1024 )))
    local d_uf;   d_uf=$(fmt_bytes $(( d_us * 1024 )))
    local d_tf;   d_tf=$(fmt_bytes $(( d_sz * 1024 )))
    local nrf;    nrf=$(fmt_bytes "$net_rx")
    local ntf;    ntf=$(fmt_bytes "$net_tx")

    fwd_v=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
    systemctl is-active --quiet warp-relay-watchdog 2>/dev/null \
        && wd_s="${ZG}● watchdog${Z0}" || wd_s="${ZR}○ watchdog${Z0}"
    systemctl is-active --quiet warp-relay-apply 2>/dev/null \
        && ap_s="${ZG}● apply${Z0}"   || ap_s="${ZR}○ apply${Z0}"
    [[ "$fwd_v" == "1" ]] \
        && fwd_s="${ZG}● fwd${Z0}"   || fwd_s="${ZR}✗ fwd${Z0}"

    printf "  %s%-24s%s  CPU %s %s%3d%%%s   Load %s%s%s   Uptime %s%s%s   %s   %s   %s\n" \
           "$ZD" "$os" "$Z0" \
           "$cpu_b" "$ZW" "$cpu_pct" "$Z0" \
           "$ZW" "$load_avg" "$Z0" \
           "$ZW" "$uptime_str" "$Z0" \
           "$wd_s" "$ap_s" "$fwd_s"
    printf "  RAM %s %s%s%s/%s%s%s   Swap %s %s%s%s/%s%s%s   Disk %s %s%s%s/%s%s%s   Server %s↓ %s%s  %s↑ %s%s\n" \
           "$ram_b" "$ZW" "$ram_uf" "$ZD" "$ZD" "$ram_tf" "$Z0" \
           "$swp_b" "$ZW" "$swp_uf" "$ZD" "$ZD" "$swp_tf" "$Z0" \
           "$dsk_b" "$ZW" "$d_uf"   "$ZD" "$ZD" "$d_tf"   "$Z0" \
           "$ZC" "$nrf" "$Z0"  "$ZG" "$ntf" "$Z0"
}

read_key() {
    local _key=""
    IFS= read -r -s -t 1 -n 1 _key 2>/dev/null || true
    printf '%s' "${_key,,}"
}

read_mapping_number() {
    local value="$1" next=""
    while IFS= read -r -s -t 0.8 -n 1 next 2>/dev/null; do
        [[ "$next" =~ ^[0-9]$ ]] || break
        value+="$next"
    done
    printf '%s' "$value"
}

# ── Collect mapping data ───────────────────────────────────────────────────────
collect_data() {
    MAP_PORT=(); MAP_LABEL=(); MAP_DST=(); MAP_IP=()
    MAP_NCLIENTS=(); MAP_RX=(); MAP_TX=()
    declare -gA CLIENT_DATA=()
    declare -gA GEO_COUNTRY=(); declare -gA GEO_CITY=(); declare -gA GEO_ISP=()

    sysctl -w net.netfilter.nf_conntrack_acct=1 >/dev/null 2>&1 || true

    local all_ips=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        parse_mapping "$line"
        MAP_PORT+=("$M_SRC_PORT")
        MAP_LABEL+=("$M_LABEL")
        MAP_DST+=("$M_DST_HOST")
        local dst_ip; dst_ip=$(resolve_host "$M_DST_HOST")
        MAP_IP+=("$dst_ip")
        local clients; clients=$(get_clients "$M_SRC_PORT")
        CLIENT_DATA["$M_SRC_PORT"]="$clients"
        local nc=0 sum_rx=0 sum_tx=0
        if [[ -n "$clients" ]]; then
            nc=$(echo "$clients" | grep -c '[0-9]' 2>/dev/null) || nc=0
            while IFS= read -r cli; do
                [[ -z "$cli" ]] && continue
                local _cip _ctx _crx
                read -r _cip _ctx _crx <<< "$cli"
                (( sum_tx += _ctx )); (( sum_rx += _crx ))
                [[ -n "$_cip" ]] && all_ips+=("$_cip")
            done <<< "$clients"
        fi
        MAP_NCLIENTS+=("$nc")
        MAP_RX+=("$sum_rx")
        MAP_TX+=("$sum_tx")
    done < <(read_mappings)

    # Geo batch lookup
    if [[ ${#all_ips[@]} -gt 0 ]]; then
        local uips=()
        while IFS= read -r ip; do uips+=("$ip"); done \
            < <(printf '%s\n' "${all_ips[@]}" | sort -u | head -100)
        local jbody; jbody=$(printf '%s\n' "${uips[@]}" | jq -R . | jq -s . 2>/dev/null)
        local geo_res; geo_res=$(geolocate_batch "$jbody")
        if [[ -n "$geo_res" ]]; then
            local entry q cn cy isp
            while IFS= read -r entry; do
                q=$(jq -r  '.query//""'   <<< "$entry" 2>/dev/null)
                cn=$(jq -r '.country//""' <<< "$entry" 2>/dev/null)
                cy=$(jq -r '.city//""'    <<< "$entry" 2>/dev/null)
                isp=$(jq -r '.isp//""'    <<< "$entry" 2>/dev/null)
                [[ -n "$q" ]] && GEO_COUNTRY["$q"]="$cn" \
                              && GEO_CITY["$q"]="$cy"    \
                              && GEO_ISP["$q"]="$isp"
            done < <(jq -c '.[]' <<< "$geo_res" 2>/dev/null)
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# TUI SCREEN: LIVE DASHBOARD
# ══════════════════════════════════════════════════════════════════════════════
screen_live() {
    while true; do
        term_size
        collect_data
        local total_nc=0 total_rx=0 total_tx=0 i
        for i in "${!MAP_PORT[@]}"; do
            (( total_nc += MAP_NCLIENTS[$i] ))
            (( total_rx += MAP_RX[$i] ))
            (( total_tx += MAP_TX[$i] ))
        done

        clear
        draw_box "Warp Relay v${VERSION} — Live Dashboard" "$(date '+%d.%m.%Y  %H:%M:%S')"
        draw_sysbar
        printf "  %s\n" "$(sep_line $(( COLS - 2 )) "─" "$ZS")"

        local WI=3 WP=8 WL=14 WD=28 WIP=18 WT=14 WN=10
        local hI hPT hLB hDT hIP hRX hTX hNC
        printf -v hI  "%-${WI}s"  "#"
        printf -v hPT "%-${WP}s"  "Port"
        printf -v hLB "%-${WL}s"  "Label"
        printf -v hDT "%-${WD}s"  "Destination"
        printf -v hIP "%-${WIP}s" "IP Address"
        printf -v hRX "%${WT}s"   "↓ Download"
        printf -v hTX "%${WT}s"   "↑ Upload"
        printf -v hNC "%-${WN}s"  "Clients"
        printf "\n  %s%s  %s  %s  %s  %s  %s  %s  %s%s\n" \
               "$ZD" "$hI" "$hPT" "$hLB" "$hDT" "$hIP" "$hRX" "$hTX" "$hNC" "$Z0"
        printf "  %s\n" "$(sep_line $(( COLS - 2 )) "─" "$ZD")"

        for i in "${!MAP_PORT[@]}"; do
            local port="${MAP_PORT[$i]}" lbl="${MAP_LABEL[$i]}" dst="${MAP_DST[$i]}"
            local dip="${MAP_IP[$i]}"    nc="${MAP_NCLIENTS[$i]}"
            local rxb="${MAP_RX[$i]}"   txb="${MAP_TX[$i]}"
            local rxf; rxf=$(fmt_bytes "$rxb")
            local txf; txf=$(fmt_bytes "$txb")
            local rule_ok="${ZR}"
            rule_exists "$port" 2>/dev/null && rule_ok="${ZG}"
            local lbl_s="$lbl"; (( ${#lbl_s} > WL ))  && lbl_s="${lbl_s:0:$(( WL-2 ))}.."
            local dst_s="$dst"; (( ${#dst_s} > WD ))   && dst_s="${dst_s:0:$(( WD-2 ))}.."
            local ip_s="$dip";  (( ${#ip_s}  > WIP ))  && ip_s="${ip_s:0:$(( WIP-2 ))}.."
            local fI fPT fLB fDT fIP fRX fTX fNC
            printf -v fI  "%-${WI}s"  "$(( i+1 ))"
            printf -v fPT "%-${WP}s"  ":$port"
            printf -v fLB "%-${WL}s"  "$lbl_s"
            printf -v fDT "%-${WD}s"  "$dst_s"
            printf -v fIP "%-${WIP}s" "$ip_s"
            printf -v fRX "%${WT}s"   "$rxf"
            printf -v fTX "%${WT}s"   "$txf"
            printf -v fNC "%-${WN}s"  "clients: $nc"
            printf "  %s%s%s  %s%s%s  %s%s%s  %s%s%s  %s%s%s  %s%s%s  %s%s%s  %s%s%s\n" \
                   "$ZD"    "$fI"  "$Z0" \
                   "$ZT$ZB" "$fPT" "$Z0" \
                   "$ZB$ZW" "$fLB" "$Z0" \
                   "$ZD"    "$fDT" "$Z0" \
                   "$ZD"    "$fIP" "$Z0" \
                   "$ZC"    "$fRX" "$Z0" \
                   "$ZG"    "$fTX" "$Z0" \
                   "$rule_ok" "$fNC" "$Z0"
        done

        printf "\n  %s\n" "$(sep_line $(( COLS - 2 )) "─" "$ZS")"
        printf "  %sTotal clients:%s %-6s   %sAll relay traffic:%s  %s↓ %-14s%s%s↑ %s%s\n" \
               "$ZD" "$ZW" "$total_nc" "$ZD" "$Z0" \
               "$ZC" "$(fmt_bytes "$total_rx")" "$Z0" \
               "$ZG" "$(fmt_bytes "$total_tx")" "$Z0"
        printf "  %s\n" "$(sep_line $(( COLS - 2 )) "─" "$ZS")"
        printf "  %s[c]%s clients   %s[m]%s manage   %s[s]%s services   %s[r]%s refresh   %s[q]%s quit\n" \
               "$ZY" "$ZD" "$ZY" "$ZD" "$ZY" "$ZD" "$ZY" "$ZD" "$ZY" "$Z0"

        local ts_start; ts_start=$(date +%s)
        while true; do
            local k; k=$(read_key)
            case "$k" in
                q) _on_exit ;;
                c) screen_clients;  return ;;
                m) screen_manage;   return ;;
                s) screen_services; return ;;
                r) break ;;
            esac
            (( $(date +%s) - ts_start >= REFRESH_LIVE )) && break
        done
    done
}

# ══════════════════════════════════════════════════════════════════════════════
# TUI SCREEN: CLIENT VIEWER
# ══════════════════════════════════════════════════════════════════════════════
screen_clients() {
    local WN=3 WIP=16 WL=24 WP=34 WT=10
    local _paused=0
    tput rmcup 2>/dev/null  # Normal screen = scrollback works

    while true; do
        if (( _paused )); then
            local k; k=$(read_key)
            case "$k" in
                q) tput smcup 2>/dev/null; _on_exit ;;
                b) tput smcup 2>/dev/null; screen_live; return ;;
                p) _paused=0 ;;
            esac
            continue
        fi

        collect_data
        local total_nc=0 total_rx=0 total_tx=0 i
        for i in "${!MAP_PORT[@]}"; do
            (( total_nc += MAP_NCLIENTS[$i] ))
            (( total_rx += MAP_RX[$i] ))
            (( total_tx += MAP_TX[$i] ))
        done
        local W=$(( 4 + WN + 2 + WIP + 2 + WL + 2 + WP + 2 + WT + 2 + WT ))
        local SEP_W; printf -v SEP_W '─%.0s' $(seq 1 $W)
        local SEP_IN; printf -v SEP_IN '─%.0s' $(seq 1 $(( W - 4 )))

        clear
        draw_box "Warp Relay v${VERSION} — Connected Clients" "$(date '+%d.%m.%Y  %H:%M:%S')"
        draw_sysbar
        printf "\n"

        for i in "${!MAP_PORT[@]}"; do
            local port="${MAP_PORT[$i]}" lbl="${MAP_LABEL[$i]}" dst="${MAP_DST[$i]}"
            local dip="${MAP_IP[$i]}"    nc="${MAP_NCLIENTS[$i]}"
            local rxf; rxf=$(fmt_bytes "${MAP_RX[$i]}")
            local txf; txf=$(fmt_bytes "${MAP_TX[$i]}")

            printf "  %sExternal port:%s %s%s%-7s%s  %s%s%s%s  %s→%s  %s%s%s\n" \
                   "$ZD" "$Z0"  "$ZT" "$ZB" "$port" "$Z0" \
                   "$ZB" "$ZW" "$lbl" "$Z0" \
                   "$ZD" "$Z0" "$ZW" "$dst"  "$Z0"
            printf "  %s    ↓ %s%-14s%s↑ %s%-14s%sclients: %s%s%s\n" \
                   "$ZD" "$ZC" "$rxf" "$ZD" "$ZG" "$txf" "$ZD" "$ZW" "$nc" "$Z0"
            printf "  %s%s%s\n" "$ZS" "$SEP_W" "$Z0"

            local clients="${CLIENT_DATA[$port]:-}"
            if [[ -z "$clients" || "$nc" -eq 0 ]]; then
                printf "  %s    no active connections%s\n\n" "$ZD" "$Z0"
                continue
            fi

            local hN hIP hL hP hTX hRX
            printf -v hN  "%-${WN}s"         "#"
            printf -v hIP "%-${WIP}s"        "IP Address"
            printf -v hL  "%-${WL}s"         "City, Country"
            printf -v hP  "%-${WP}s"         "Provider"
            printf -v hTX "%$(( WT + 2 ))s"  "↑ Upload"
            printf -v hRX "%$(( WT + 2 ))s"  "↓ Download"
            printf "    %s%s  %s  %s  %s  %s  %s%s\n" \
                   "$ZD" "$hN" "$hIP" "$hL" "$hP" "$hTX" "$hRX" "$Z0"
            printf "    %s%s%s\n" "$ZS" "$SEP_IN" "$Z0"

            local sorted
            sorted=$(awk '{print ($2+$3)" "$0}' <<< "$clients" | sort -rn | cut -d' ' -f2-)
            local idx=1
            while IFS= read -r cli; do
                [[ -z "$cli" ]] && continue
                local cip ctx crx
                read -r cip ctx crx <<< "$cli"
                local cn cy isp loc
                cn="${GEO_COUNTRY[$cip]:-}"; cy="${GEO_CITY[$cip]:-}"; isp="${GEO_ISP[$cip]:-}"
                loc="${cy:+$cy, }${cn:----}"
                (( ${#loc} > WL )) && loc="${loc:0:$(( WL-3 ))}..."
                (( ${#isp} > WP )) && isp="${isp:0:$(( WP-3 ))}..."
                local txf2; txf2=$(fmt_bytes "$ctx")
                local rxf2; rxf2=$(fmt_bytes "$crx")
                local tclr="$ZW"
                local tot=$(( ctx + crx ))
                (( tot > 10485760   )) && tclr="$ZG"
                (( tot > 104857600  )) && tclr="$ZY"
                (( tot > 1073741824 )) && tclr="$ZR"
                local fN fIP fL fP fTX fRX
                printf -v fN  "%-${WN}s"  "$idx"
                printf -v fIP "%-${WIP}s" "$cip"
                printf -v fL  "%-${WL}s"  "$loc"
                printf -v fP  "%-${WP}s"  "$isp"
                printf -v fTX "%${WT}s"   "$txf2"
                printf -v fRX "%${WT}s"   "$rxf2"
                printf "    %s%s%s  %s%s%s  %s%s%s  %s%s%s  %s%s%s  %s%s%s\n" \
                       "$ZD" "$fN"  "$Z0" \
                       "$ZW" "$fIP" "$Z0" \
                       "$ZC" "$fL"  "$Z0" \
                       "$ZD" "$fP"  "$Z0" \
                       "$tclr" "$fTX" "$Z0" \
                       "$tclr" "$fRX" "$Z0"
                (( idx++ ))
            done <<< "$sorted"
            printf "\n"
        done

        printf "  %s\n" "$(sep_line $(( COLS - 2 )) "─" "$ZS")"
        printf "  %sTotal clients:%s %-6s   %sAll relay traffic:%s  %s↓ %-14s%s%s↑ %s%s\n" \
               "$ZD" "$ZW" "$total_nc" "$ZD" "$Z0" \
               "$ZC" "$(fmt_bytes "$total_rx")" "$Z0" \
               "$ZG" "$(fmt_bytes "$total_tx")" "$Z0"
        printf "  %s\n" "$(sep_line $(( COLS - 2 )) "─" "$ZS")"
        printf "  %s[b]%s back   %s[r]%s refresh   %s[p]%s pause/scroll   %s[q]%s quit\n" \
               "$ZY" "$ZD" "$ZY" "$ZD" "$ZY" "$ZD" "$ZY" "$Z0"

        local ts_start; ts_start=$(date +%s)
        while true; do
            local k; k=$(read_key)
            case "$k" in
                q) tput smcup 2>/dev/null; _on_exit ;;
                b) tput smcup 2>/dev/null; screen_live; return ;;
                r) break ;;
                p) _paused=1
                   printf "\n  %s⏸  PAUSED — scroll freely, press [p] to resume%s\n" "$ZY" "$Z0"
                   break ;;
            esac
            (( $(date +%s) - ts_start >= REFRESH_LIVE )) && break
        done
    done
    tput smcup 2>/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
# TUI SCREEN: MANAGE MAPPINGS
# NOTE: [n] = New mapping,  [R] = Re-apply all rules to iptables,  [f] = Flush
# ══════════════════════════════════════════════════════════════════════════════
screen_manage() {
    while true; do
        term_size
        clear
        draw_box "Warp Relay v${VERSION} — Manage Mappings" "$(date '+%H:%M:%S')"
        draw_sysbar
        printf "  %s\n\n" "$(sep_line $(( COLS - 2 )) "─" "$ZS")"

        printf "  %s  %-4s  %-8s  %-14s  %-28s  %-8s  %s%s\n" \
               "$ZD" "#" "Port" "Label" "Destination" "Dst Port" "Status" "$Z0"
        printf "  %s\n" "$(sep_line $(( COLS - 2 )) "─" "$ZD")"

        local mappings=()
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            mappings+=("$line")
        done < <(read_mappings)

        local i
        for i in "${!mappings[@]}"; do
            parse_mapping "${mappings[$i]}"
            local ok="${ZR}✗ inactive${Z0}"
            rule_exists "$M_SRC_PORT" 2>/dev/null && ok="${ZG}● active${Z0}"
            printf "  %s  %-4s%s  %s%s%-8s%s  %s%-14s%s  %s%-28s%s  %s%-8s%s  %s\n" \
                   "$ZD" "$(( i+1 ))" "$Z0" \
                   "$ZT" "$ZB" ":$M_SRC_PORT" "$Z0" \
                   "$ZW" "${M_LABEL:0:14}" "$Z0" \
                   "$ZD" "${M_DST_HOST:0:28}" "$Z0" \
                   "$ZD" ":$M_DST_PORT" "$Z0" \
                   "$ok"
        done

        printf "\n  %s\n" "$(sep_line $(( COLS - 2 )) "─" "$ZS")"
        printf "  %s[1-%s]%s select mapping\n" "$ZY" "${#mappings[@]}" "$ZD"
        printf "  %s[n]%s  New mapping        %s[R]%s  Re-apply all rules to iptables\n" \
               "$ZY" "$ZD"  "$ZY" "$ZD"
        printf "  %s[f]%s  Flush all rules    %s[w]%s  WARP auto-setup\n" \
               "$ZY" "$ZD"  "$ZY" "$ZD"
        printf "  %s[b]%s  Back               %s[q]%s  Quit\n" "$ZY" "$ZD" "$ZY" "$Z0"

        local ts_mgr; ts_mgr=$(date +%s)
        local k=""
        while true; do
            k=$(read_key)
            case "$k" in
                q) _on_exit ;;
                b) screen_live; return ;;
                n) screen_add_mapping;  return ;;
                r) clear  # Re-apply all — intentional uppercase R, but read_key lowercases
                   printf "\n  %sRe-applying all rules to iptables...%s\n" "$ZY" "$Z0"
                   local cnt; cnt=$(apply_all)
                   printf "  %sApplied %s rule(s).%s\n" "$ZG" "$cnt" "$Z0"
                   sleep 1; break ;;
                f) clear
                   printf "\n  %sFlushing all WR rules from iptables...%s\n" "$ZR" "$Z0"
                   flush_all_rules
                   printf "  %sDone.%s\n" "$ZG" "$Z0"
                   sleep 1; break ;;
                w) screen_warp; return ;;
                [1-9])
                    local selected="$k"
                    if (( ${#mappings[@]} >= 10 )); then
                        selected=$(read_mapping_number "$k")
                    fi
                    local num=$(( selected - 1 ))
                    if [[ $num -lt ${#mappings[@]} ]]; then
                        screen_mapping_actions "${mappings[$num]}"
                        return
                    fi ;;
            esac
            (( $(date +%s) - ts_mgr >= REFRESH_LIVE )) && break
        done
    done
}

# ── Per-mapping action screen ──────────────────────────────────────────────────
screen_mapping_actions() {
    local mapping_line="$1"
    parse_mapping "$mapping_line"
    local port="$M_SRC_PORT" lbl="$M_LABEL" dst="$M_DST_HOST" dport="$M_DST_PORT"

    while true; do
        clear
        draw_box "Warp Relay v${VERSION} — Mapping :${port}  ${lbl}" "→ ${dst}:${dport}"
        printf "\n"
        local dst_ip; dst_ip=$(resolve_host "$dst")
        local ok="${ZR}✗ inactive${Z0}"
        rule_exists "$port" 2>/dev/null && ok="${ZG}● active${Z0}"

        printf "  %sPort:%s    %s%s:%-8s%s\n" "$ZD" "$Z0" "$ZT" "$ZB" "$port" "$Z0"
        printf "  %sLabel:%s   %s%s%s\n"       "$ZD" "$Z0" "$ZW" "$lbl" "$Z0"
        printf "  %sTarget:%s  %s%s%s → %s%s%s  %s(%s)%s\n" \
               "$ZD" "$Z0"  "$ZW" "$dst" "$Z0" "$ZD" "$dport" "$Z0" "$ZD" "$dst_ip" "$Z0"
        printf "  %sStatus:%s  %s\n\n" "$ZD" "$Z0" "$ok"
        printf "  %s\n" "$(sep_line $(( COLS - 2 )) "─" "$ZS")"
        printf "  %s[1]%s Apply/restart rules   %s[2]%s Remove rules   %s[3]%s Flush conntrack\n" \
               "$ZY" "$ZD" "$ZY" "$ZD" "$ZY" "$ZD"
        printf "  %s[4]%s View clients          %s[5]%s Edit            %s[6]%s Delete\n" \
               "$ZY" "$ZD" "$ZY" "$ZD" "$ZY" "$ZD"
        printf "  %s[b]%s Back\n" "$ZY" "$Z0"

        local ts_act; ts_act=$(date +%s)
        while true; do
            local k; k=$(read_key)
            case "$k" in
                b) screen_manage; return ;;
                q) _on_exit ;;
                1) clear
                   printf "\n  %sApplying :${port} → ${dst}:${dport}...%s\n" "$ZY" "$Z0"
                   apply_one "$port" "$dst_ip" "$dport"; save_rules
                   printf "  %sDone.%s\n" "$ZG" "$Z0"; sleep 1; break ;;
                2) clear
                   printf "\n  %sRemoving rules for :${port}...%s\n" "$ZY" "$Z0"
                   remove_one_rules "$port" "$dst_ip" "$dport"; save_rules
                   printf "  %sDone.%s\n" "$ZG" "$Z0"; sleep 1; break ;;
                3) clear
                   printf "\n  %sFlushing conntrack for ${dst_ip}...%s\n" "$ZY" "$Z0"
                   flush_conntrack_for "$dst_ip"
                   printf "  %sDone.%s\n" "$ZG" "$Z0"; sleep 1; break ;;
                4) screen_clients; return ;;
                5) screen_edit_mapping "$mapping_line"; return ;;
                6) screen_delete_mapping "$mapping_line"; return ;;
            esac
            (( $(date +%s) - ts_act >= REFRESH_LIVE )) && break
        done
    done
}

# ── Add / Edit / Delete mappings ──────────────────────────────────────────────
screen_add_mapping() {
    cursor_show; clear
    draw_box "Warp Relay v${VERSION} — New Mapping" ""
    printf "\n"
    local src_port dst_host dst_port lbl
    printf "  %sExternal UDP port%s (e.g. 51820): " "$ZY" "$Z0"; read -r src_port
    [[ -z "$src_port" ]] && { cursor_hide; screen_manage; return; }
    printf "  %sDestination host%s (e.g. de.vpn.com): " "$ZY" "$Z0"; read -r dst_host
    [[ -z "$dst_host"  ]] && { cursor_hide; screen_manage; return; }
    printf "  %sDestination port%s [${src_port}]: " "$ZY" "$Z0"; read -r dst_port
    dst_port="${dst_port:-$src_port}"
    printf "  %sLabel%s (e.g. Germany-WG): " "$ZY" "$Z0"; read -r lbl
    [[ -z "$lbl" ]] && lbl="$dst_host"
    mkdir -p "$CONFIG_DIR"
    printf "0.0.0.0 %s %s %s %s\n" "$src_port" "$dst_host" "$dst_port" "$lbl" >> "$CONFIG_FILE"
    printf "\n  %sSaved: :${src_port} → ${dst_host}:${dst_port} (${lbl})%s\n" "$ZG" "$Z0"
    printf "  %sApply rules to iptables now? [y/N]%s " "$ZY" "$Z0"; read -r ans
    if [[ "${ans,,}" == "y" ]]; then
        local dst_ip; dst_ip=$(resolve_host "$dst_host")
        apply_one "$src_port" "$dst_ip" "$dst_port"; save_rules
        printf "  %sRules applied.%s\n" "$ZG" "$Z0"
    fi
    log_msg "added mapping :${src_port} → ${dst_host}:${dst_port} [${lbl}]"
    sleep 1; cursor_hide; screen_manage; return
}

screen_edit_mapping() {
    local old_line="$1"
    parse_mapping "$old_line"
    cursor_show; clear
    draw_box "Warp Relay v${VERSION} — Edit :${M_SRC_PORT}" ""
    printf "\n  %sLeave blank to keep current value.%s\n\n" "$ZD" "$Z0"
    local np nh nd nl
    printf "  %sPort%s        [%s]: "  "$ZY" "$Z0" "$M_SRC_PORT";  read -r np
    printf "  %sDst host%s    [%s]: "  "$ZY" "$Z0" "$M_DST_HOST";  read -r nh
    printf "  %sDst port%s    [%s]: "  "$ZY" "$Z0" "$M_DST_PORT";  read -r nd
    printf "  %sLabel%s       [%s]: "  "$ZY" "$Z0" "$M_LABEL";     read -r nl
    [[ -z "$np" ]] && np="$M_SRC_PORT"
    [[ -z "$nh" ]] && nh="$M_DST_HOST"
    [[ -z "$nd" ]] && nd="$M_DST_PORT"
    [[ -z "$nl" ]] && nl="$M_LABEL"
    local new_line="0.0.0.0 $np $nh $nd $nl"
    local tmpf; tmpf=$(mktemp)
    while IFS= read -r line; do
        [[ "$line" == "$old_line" ]] && echo "$new_line" || echo "$line"
    done < "$CONFIG_FILE" > "$tmpf"
    mv "$tmpf" "$CONFIG_FILE"
    printf "\n  %sUpdated.%s Apply rules? [y/N] " "$ZG" "$Z0"; read -r ans
    if [[ "${ans,,}" == "y" ]]; then
        remove_one_rules "$M_SRC_PORT" "$(resolve_host "$M_DST_HOST")" "$M_DST_PORT" 2>/dev/null || true
        apply_one "$np" "$(resolve_host "$nh")" "$nd"; save_rules
        printf "  %sRules applied.%s\n" "$ZG" "$Z0"
    fi
    log_msg "edited mapping :${M_SRC_PORT} → :${np}"
    sleep 1; cursor_hide; screen_manage; return
}

screen_delete_mapping() {
    local old_line="$1"
    parse_mapping "$old_line"
    cursor_show; clear
    draw_box "Warp Relay v${VERSION} — Delete :${M_SRC_PORT}" ""
    printf "\n  %sDelete: :${M_SRC_PORT} → ${M_DST_HOST}:${M_DST_PORT} (${M_LABEL})%s\n\n" "$ZR" "$Z0"
    printf "  %sConfirm? [y/N]%s " "$ZY" "$Z0"; read -r ans
    if [[ "${ans,,}" == "y" ]]; then
        remove_one_rules "$M_SRC_PORT" "$(resolve_host "$M_DST_HOST")" "$M_DST_PORT" 2>/dev/null || true
        local tmpf; tmpf=$(mktemp)
        grep -Fxv "$old_line" "$CONFIG_FILE" > "$tmpf" 2>/dev/null || true
        mv "$tmpf" "$CONFIG_FILE"
        save_rules
        printf "  %sDeleted.%s\n" "$ZG" "$Z0"
        log_msg "deleted mapping :${M_SRC_PORT}"
    fi
    sleep 1; cursor_hide; screen_manage; return
}

# ══════════════════════════════════════════════════════════════════════════════
# TUI SCREEN: WARP AUTO-SETUP
# ══════════════════════════════════════════════════════════════════════════════
screen_warp() {
    cursor_show; clear
    draw_box "Warp Relay v${VERSION} — Cloudflare WARP Setup" ""
    printf "\n"
    printf "  %sCloudflare WARP%s: clients use %s:%s/UDP%s on this relay → %s%s:%s%s\n" \
           "$ZW" "$Z0" "$ZT" "$WARP_SRC_PORT" "$Z0" "$ZC" "$WARP_HOST" "$WARP_DST_PORT" "$Z0"
    printf "  %s(2408 is WARP's WireGuard data port; 4500→4500 never worked)%s\n" "$ZD" "$Z0"
    printf "\n"

    if port_in_use "$WARP_SRC_PORT"; then
        printf "  %sWARP mapping already configured (port %s).%s\n\n" "$ZG" "$WARP_SRC_PORT" "$Z0"
        printf "  %s[r]%s Remove WARP mapping   %s[b]%s Back\n" "$ZY" "$ZD" "$ZY" "$Z0"
        while true; do
            local k; k=$(read_key)
            case "$k" in
                b) cursor_hide; screen_manage; return ;;
                r) read -rp "  Remove WARP mapping? [y/N]: " ans
                   if [[ "${ans,,}" == "y" ]]; then
                       local tmpf; tmpf=$(mktemp)
                       grep -v "$WARP_HOST" "$CONFIG_FILE" > "$tmpf" 2>/dev/null || true
                       mv "$tmpf" "$CONFIG_FILE"
                       remove_one_rules "$WARP_SRC_PORT" "" "" 2>/dev/null || true; save_rules
                       printf "  %sWARP mapping removed.%s\n" "$ZG" "$Z0"
                       sleep 1
                   fi
                   cursor_hide; screen_manage; return ;;
            esac
        done
    fi

    printf "  Detecting relay public IP and resolving WARP endpoint...\n\n"
    local src_ip; src_ip=$(detect_public_ip)
    printf "  %sRelay IP:%s   %s%s%s\n" "$ZD" "$Z0" "$ZW" "$src_ip" "$Z0"

    local dst_ip; dst_ip=$(resolve_host "$WARP_HOST" 2>/dev/null) || dst_ip=""
    if [[ -z "$dst_ip" || "$dst_ip" == "?" ]]; then
        printf "  %sCannot resolve %s%s\n" "$ZR" "$WARP_HOST" "$Z0"
        printf "\n  Press any key...\n"; read -r -s -n 1
        cursor_hide; screen_manage; return
    fi
    printf "  %sWARP IP:%s    %s%s%s\n" "$ZD" "$Z0" "$ZW" "$dst_ip" "$Z0"
    printf "\n  %s:%s%s → %s%s:%s%s\n\n" "$ZT" "$WARP_SRC_PORT" "$Z0" "$ZW" "$dst_ip" "$WARP_DST_PORT" "$Z0"

    read -rp "  Add WARP mapping and apply rules? [Y/n]: " ans
    if [[ "${ans,,}" != "n" ]]; then
        printf "0.0.0.0 %s %s %s cloudflare-warp\n" "$WARP_SRC_PORT" "$WARP_HOST" "$WARP_DST_PORT" >> "$CONFIG_FILE"
        apply_one "$WARP_SRC_PORT" "$dst_ip" "$WARP_DST_PORT"; save_rules
        printf "\n  %sWARP configured and rules applied.%s\n" "$ZG" "$Z0"
        log_msg "WARP setup: :${WARP_SRC_PORT} → ${dst_ip}:${WARP_DST_PORT}"
    fi
    sleep 1; cursor_hide; screen_manage; return
}

# ══════════════════════════════════════════════════════════════════════════════
# TUI SCREEN: DIAGNOSTICS
# ══════════════════════════════════════════════════════════════════════════════
screen_diagnostics() {
    cursor_show; clear
    draw_box "Warp Relay v${VERSION} — Diagnostics" ""
    printf "\n"

    # System checks
    local fwd; fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "?")
    [[ "$fwd" == "1" ]] \
        && printf "  %s✓%s  IP forwarding: %sON%s\n" "$ZG" "$Z0" "$ZG" "$Z0" \
        || printf "  %s✗%s  IP forwarding: %sOFF — run: sysctl -w net.ipv4.ip_forward=1%s\n" "$ZR" "$Z0" "$ZR" "$Z0"

    local ct_cur ct_max
    ct_cur=$(conntrack -L 2>/dev/null | wc -l || echo "?")
    ct_max=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo "?")
    printf "  %s»%s  Conntrack: %s%s%s / %s\n" "$ZC" "$Z0" "$ZW" "$ct_cur" "$Z0" "$ct_max"

    local nat_cnt fwd_cnt
    nat_cnt=$(iptables -t nat -S 2>/dev/null | grep -c "$TAG" 2>/dev/null) || nat_cnt=0
    fwd_cnt=$(iptables -S 2>/dev/null | grep -c "$TAG" 2>/dev/null) || fwd_cnt=0
    [[ $nat_cnt -gt 0 ]] \
        && printf "  %s✓%s  NAT rules: %s%s%s\n" "$ZG" "$Z0" "$ZW" "$nat_cnt" "$Z0" \
        || printf "  %s✗%s  NAT rules: %s0 — not applied!%s\n" "$ZR" "$Z0" "$ZR" "$Z0"
    printf "  %s»%s  FORWARD rules: %s%s%s\n" "$ZC" "$Z0" "$ZW" "$fwd_cnt" "$Z0"

    local iptver
    iptver=$(iptables --version 2>/dev/null | head -1)
    printf "  %s»%s  %s\n\n" "$ZC" "$Z0" "$iptver"

    printf "  %s\n" "$(sep_line $(( COLS - 2 )) "─" "$ZS")"
    printf "  %sMappings:%s\n\n" "$ZW" "$Z0"

    local idx=1
    while IFS= read -r line; do
        parse_mapping "$line"
        local dst_ip; dst_ip=$(resolve_host "$M_DST_HOST" 2>/dev/null) || dst_ip=""
        local dns_ok rule_ok ct_cnt bytes
        [[ -n "$dst_ip" && "$dst_ip" != "?" ]] \
            && dns_ok="${ZG}✓ ${dst_ip}${Z0}" \
            || dns_ok="${ZR}✗ unresolvable${Z0}"
        rule_exists "$M_SRC_PORT" 2>/dev/null \
            && rule_ok="${ZG}✓ active${Z0}" \
            || rule_ok="${ZR}✗ MISSING${Z0}"
        ct_cnt=$(conntrack -L -d "${dst_ip:-0}" 2>/dev/null | grep -c "udp" 2>/dev/null) || ct_cnt=0
        bytes=$(fmt_bytes "$(iptables -L FORWARD -v -n -x 2>/dev/null \
            | awk -v ip="${dst_ip:-0}" -v p="$M_DST_PORT" '$0~ip&&$0~p{s+=$2} END{print s+0}')")
        printf "  %s#%s %s%s%s  → %s%s%s\n" \
               "$ZB" "$Z0" "$ZT" ":$M_SRC_PORT" "$Z0" "$ZC" "$M_DST_HOST:$M_DST_PORT" "$Z0"
        printf "    DNS: %s     Rule: %s\n" "$dns_ok" "$rule_ok"
        printf "    %sConntrack:%s %s sessions   %sBytes:%s %s\n" \
               "$ZD" "$ZW" "${ct_cnt:-0}" "$ZD" "$ZW" "$bytes"
        printf "\n"
        (( idx++ ))
    done < <(read_mappings)

    [[ $idx -eq 1 ]] && printf "  %s(no mappings configured)%s\n" "$ZD" "$Z0"

    printf "  %s\n" "$(sep_line $(( COLS - 2 )) "─" "$ZS")"
    printf "  %s[b]%s back   %s[press any key]%s\n" "$ZY" "$ZD" "$ZD" "$Z0"
    read -r -s -n 1
    cursor_hide
}

# ══════════════════════════════════════════════════════════════════════════════
# TUI SCREEN: SERVICES
# ══════════════════════════════════════════════════════════════════════════════
screen_services() {
    local SVCS=("warp-relay-sysctl-reapply" "warp-relay-apply" "warp-relay-watchdog")
    while true; do
        clear
        draw_box "Warp Relay v${VERSION} — Services" "$(date '+%H:%M:%S')"
        printf "\n"
        local svc
        for svc in "${SVCS[@]}"; do
            local active enabled
            active=$(systemctl is-active  "$svc" 2>/dev/null || echo "inactive")
            enabled=$(systemctl is-enabled "$svc" 2>/dev/null || echo "disabled")
            local ac="${ZR}"; [[ "$active"  == "active"  ]] && ac="${ZG}"
            local en="${ZR}"; [[ "$enabled" == "enabled" ]] && en="${ZG}"
            printf "  %s%-34s%s  status: %s%-10s%s  boot: %s%s%s\n" \
                   "$ZW" "$svc" "$Z0" "$ac" "$active" "$Z0" "$en" "$enabled" "$Z0"
        done
        printf "\n  %s\n" "$(sep_line $(( COLS - 2 )) "─" "$ZS")"
        printf "  %s[1]%s Start   %s[2]%s Stop   %s[3]%s Restart   %s[4]%s Enable boot   %s[5]%s Disable boot\n" \
               "$ZY" "$ZD" "$ZY" "$ZD" "$ZY" "$ZD" "$ZY" "$ZD" "$ZY" "$ZD"
        printf "  %s[6]%s (Re)install services + scripts\n" "$ZY" "$ZD"
        printf "  %s[7]%s Uninstall services\n" "$ZY" "$ZD"
        printf "  %s[b]%s Back   %s[q]%s Quit\n" "$ZY" "$ZD" "$ZY" "$Z0"

        local ts_svc; ts_svc=$(date +%s)
        while true; do
            local k; k=$(read_key)
            case "$k" in
                b) screen_live;    return ;;
                q) _on_exit ;;
                1) for svc in "${SVCS[@]}"; do systemctl start   "$svc" 2>/dev/null; done; break ;;
                2) for svc in "${SVCS[@]}"; do systemctl stop    "$svc" 2>/dev/null; done; break ;;
                3) for svc in "${SVCS[@]}"; do systemctl restart "$svc" 2>/dev/null; done; break ;;
                4) for svc in "${SVCS[@]}"; do systemctl enable  "$svc" 2>/dev/null; done; break ;;
                5) for svc in "${SVCS[@]}"; do systemctl disable "$svc" 2>/dev/null; done; break ;;
                6) screen_reinstall_services; return ;;
                7) screen_uninstall_services; return ;;
            esac
            (( $(date +%s) - ts_svc >= REFRESH_LIVE )) && break
        done
    done
}

screen_reinstall_services() {
    cursor_show; clear
    printf "\n  %s(Re)installing warp-relay services...%s\n\n" "$ZY" "$Z0"
    apply_sysctl
    printf "  %s✓%s  sysctl\n" "$ZG" "$Z0"
    write_apply_script
    printf "  %s✓%s  apply script: %s\n" "$ZG" "$Z0" "$APPLY_SCRIPT"
    write_watchdog_script
    printf "  %s✓%s  watchdog script: %s\n" "$ZG" "$Z0" "$WATCHDOG_SCRIPT"
    write_services
    printf "  %s✓%s  systemd unit files\n" "$ZG" "$Z0"
    systemctl daemon-reload
    systemctl enable --now warp-relay-sysctl-reapply 2>/dev/null
    systemctl enable --now warp-relay-apply    2>/dev/null
    systemctl enable --now warp-relay-watchdog 2>/dev/null
    printf "  %s✓%s  services enabled and started\n" "$ZG" "$Z0"
    install_relay_bin
    printf "  %s✓%s  relay binary updated: %s\n\n" "$ZG" "$Z0" "$RELAY_BIN"
    printf "  Press any key...\n"; read -r -s -n 1
    cursor_hide; screen_services; return
}

screen_uninstall_services() {
    cursor_show; clear
    printf "\n  %sUninstalling services...%s\n" "$ZR" "$Z0"
    uninstall_all_services
    printf "  %sDone.%s\n\n" "$ZG" "$Z0"
    printf "  Press any key...\n"; read -r -s -n 1
    cursor_hide; screen_services; return
}

# ══════════════════════════════════════════════════════════════════════════════
# TUI SCREEN: LOG
# ══════════════════════════════════════════════════════════════════════════════
screen_log() {
    cursor_show; clear
    draw_box "Warp Relay v${VERSION} — Log" "$LOG_FILE"
    printf "\n"
    if [[ -f "$LOG_FILE" && -s "$LOG_FILE" ]]; then
        tail -40 "$LOG_FILE" | while IFS= read -r line; do
            local clr="$ZD"
            [[ "$line" == *"STALL"*  || "$line" == *"WARN"*    ]] && clr="$ZY"
            [[ "$line" == *"ERROR"*  || "$line" == *"missing"* ]] && clr="$ZR"
            [[ "$line" == *" OK:"*   || "$line" == *"done"*    ]] && clr="$ZG"
            [[ "$line" == *"applied"*                          ]] && clr="$ZG"
            printf "  %s%s%s\n" "$clr" "$line" "$Z0"
        done
    else
        printf "  %s(log empty)%s\n" "$ZD" "$Z0"
    fi
    printf "\n  %s\n" "$(sep_line $(( COLS - 2 )) "─" "$ZS")"
    printf "  %s[c]%s clear log   %spress any key to go back%s\n" "$ZY" "$ZD" "$ZD" "$Z0"
    local k; IFS= read -r -s -n 1 k 2>/dev/null || true
    [[ "${k,,}" == "c" ]] && { : > "$LOG_FILE"; }
    cursor_hide
}

# ══════════════════════════════════════════════════════════════════════════════
# TUI SCREEN: MAIN MENU
# ══════════════════════════════════════════════════════════════════════════════
screen_main() {
    while true; do
        term_size
        clear
        draw_box "Warp Relay Management Console v${VERSION}" \
                 "$(date '+%d.%m.%Y  %H:%M:%S')"
        draw_sysbar
        printf "  %s\n\n" "$(sep_line $(( COLS - 2 )) "─" "$ZS")"

        local nm; nm=$(count_mappings)
        printf "  %sMappings:%s %s   %sConfig:%s %s\n\n" \
               "$ZD" "$ZW" "$nm" "$ZD" "$ZD" "$CONFIG_FILE"

        printf "  %s%s[1]%s  %sLive Dashboard%s       %sauto-refresh, system stats + relay overview%s\n" \
               "$ZY" "$ZB" "$Z0" "$ZW" "$Z0" "$ZD" "$Z0"
        printf "  %s%s[2]%s  %sConnected Clients%s    %sper-IP traffic, geo, provider%s\n" \
               "$ZY" "$ZB" "$Z0" "$ZW" "$Z0" "$ZD" "$Z0"
        printf "  %s%s[3]%s  %sManage Mappings%s      %sadd / edit / delete / re-apply%s\n" \
               "$ZY" "$ZB" "$Z0" "$ZW" "$Z0" "$ZD" "$Z0"
        printf "  %s%s[4]%s  %sServices%s             %sstart / stop / reinstall systemd%s\n" \
               "$ZY" "$ZB" "$Z0" "$ZW" "$Z0" "$ZD" "$Z0"
        printf "  %s%s[5]%s  %sDiagnostics%s          %srule checks, conntrack, DNS%s\n" \
               "$ZY" "$ZB" "$Z0" "$ZW" "$Z0" "$ZD" "$Z0"
        printf "  %s%s[6]%s  %sLog%s\n" \
               "$ZY" "$ZB" "$Z0" "$ZW" "$Z0"
        printf "  %s%s[q]%s  %sQuit%s\n\n" \
               "$ZY" "$ZB" "$Z0" "$ZR" "$Z0"

        printf "  %s\n  %sSelect:%s " "$(sep_line $(( COLS - 2 )) "─" "$ZS")" "$ZD" "$Z0"

        local ts_menu; ts_menu=$(date +%s)
        while true; do
            local k; k=$(read_key)
            case "$k" in
                1) screen_live;        return ;;
                2) screen_clients;     return ;;
                3) screen_manage;      return ;;
                4) screen_services;    return ;;
                5) screen_diagnostics; return ;;
                6) screen_log;         return ;;
                q) _on_exit ;;
            esac
            (( $(date +%s) - ts_menu >= REFRESH_LIVE )) && break
        done
    done
}

# ══════════════════════════════════════════════════════════════════════════════
# ENTRY POINT
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$SCRIPT_MODE" == "setup" ]]; then
    run_setup
else
    # TUI mode — called as 'relay'
    check_tui_deps
    mkdir -p "$CONFIG_DIR"
    [[ -f "$CONFIG_FILE" ]] || touch "$CONFIG_FILE"
    init_term
    screen_main
fi
