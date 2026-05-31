#!/bin/bash

# PROVIDERDNS_MANAGED=1

set -o pipefail

ROOT="${PROVIDERDNS_ROOT:-/}"
API_VERSION="1"
DEFAULT_TIMEOUT="5"

log() { printf '[providerdns] %s\n' "$*"; }
fail() { printf '[providerdns] FAIL %s\n' "$*" >&2; exit 1; }

path() {
    if [ "$ROOT" = "/" ]; then
        printf '%s\n' "$1"
    else
        printf '%s%s\n' "$ROOT" "$1"
    fi
}

trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

script_path() {
    local resolved base
    resolved="$(command -v readlink >/dev/null 2>&1 && readlink -f "$0" 2>/dev/null || true)"
    if [ -z "$resolved" ]; then
        base="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
        resolved="${base}/$(basename "$0")"
    fi
    printf '%s\n' "$resolved"
}

require_root() {
    [ "$ROOT" != "/" ] && return 0
    [ "$(id -u)" = "0" ] || fail "need root"
}

subscription_dir() { path "/etc/provider/dns/subscriptions"; }
hook_dir() { path "/etc/provider/dns/hooks"; }
state_dir() { path "/var/lib/provider/dns"; }
cache_file() { path "/var/lib/provider/dns/cache.tsv"; }
lock_file() { path "/run/providerdns.lock"; }
service_file() { path "/etc/systemd/system/providerdns.service"; }
timer_file() { path "/etc/systemd/system/providerdns.timer"; }
systemd_dir() { path "/etc/systemd/system"; }

validate_ipv4() {
    local ip="$1" octet old_ifs
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    old_ifs="$IFS"; IFS=.; set -- $ip; IFS="$old_ifs"
    [ "$#" -eq 4 ] || return 1
    for octet in "$@"; do
        [[ "$octet" =~ ^[0-9]+$ ]] && [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
    done
}

validate_domain() {
    local domain="$1"
    [ -n "$domain" ] && [ "${#domain}" -le 253 ] &&
        [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?([.][A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}

cache_field() {
    local domain="$1" field="$2" file
    file="$(cache_file)"
    [ -s "$file" ] || return 1
    awk -v d="$domain" -v f="$field" '$1==d { print $f; found=1; exit } END { exit(found ? 0 : 1) }' "$file"
}

cache_ip() {
    local ip
    ip="$(cache_field "$1" 2 2>/dev/null || true)"
    validate_ipv4 "$ip" || return 1
    printf '%s\n' "$ip"
}

resolve_ipv4() {
    local domain="$1" ip timeout_value
    if [ -n "${PROVIDERDNS_HOSTS_FILE:-}" ]; then
        ip="$(awk -v d="$domain" '$1==d { print $2; exit }' "$PROVIDERDNS_HOSTS_FILE")"
    else
        command -v getent >/dev/null 2>&1 || return 1
        timeout_value="${PROVIDERDNS_TIMEOUT:-$DEFAULT_TIMEOUT}"
        if command -v timeout >/dev/null 2>&1; then
            ip="$(timeout "${timeout_value}s" getent ahostsv4 "$domain" 2>/dev/null | awk '/STREAM/ { print $1; exit }')"
        else
            ip="$(getent ahostsv4 "$domain" 2>/dev/null | awk '/STREAM/ { print $1; exit }')"
        fi
    fi
    validate_ipv4 "$ip" || return 1
    printf '%s\n' "$ip"
}

collect_domains() {
    local output="$1" dir file line domain
    dir="$(subscription_dir)"
    mkdir -p "$dir" || return 1
    : > "$output" || return 1
    for file in "$dir"/*.list; do
        [ -f "$file" ] || continue
        while IFS= read -r line || [ -n "$line" ]; do
            domain="$(trim "${line%%#*}")"
            [ -n "$domain" ] || continue
            validate_domain "$domain" || continue
            printf '%s\n' "$domain" >> "$output"
        done < "$file"
    done
    sort -u "$output" -o "$output"
}

write_cache_line() {
    local domain="$1" ip="$2" status="$3" now="$4" old_ip="${5:-}" old_status="${6:-}" old_time="${7:-}" updated_at
    if [ "$old_ip" = "$ip" ] && [ "$old_status" = "$status" ] && [ -n "$old_time" ]; then
        updated_at="$old_time"
    else
        updated_at="$now"
    fi
    printf '%s\t%s\t%s\t%s\n' "$domain" "$ip" "$status" "$updated_at"
}

run_hooks() {
    local dir hook failed=0
    dir="$(hook_dir)"
    [ -d "$dir" ] || return 0
    for hook in "$dir"/*; do
        [ -x "$hook" ] || continue
        "$hook" || failed=$((failed + 1))
    done
    [ "$failed" -eq 0 ] || { log "hookfail=${failed}"; return 1; }
}

refresh_cache() {
    local run_hooks="${1:-0}" domains tmp oldcache cache domain old_domain now ip old_ip old_status old_time changed=0
    mkdir -p "$(subscription_dir)" "$(hook_dir)" "$(state_dir)" || fail "dir"
    if command -v flock >/dev/null 2>&1; then
        exec 8>"$(lock_file)" || fail "lock"
        flock -n 8 || { log "locked"; return 0; }
    fi

    domains="$(mktemp /tmp/providerdns-domains.XXXXXX)" || fail "temp"
    tmp="$(mktemp /tmp/providerdns-cache.XXXXXX)" || { rm -f "$domains"; fail "temp"; }
    oldcache="$(mktemp /tmp/providerdns-old.XXXXXX)" || { rm -f "$domains" "$tmp"; fail "temp"; }
    cache="$(cache_file)"

    collect_domains "$domains" || { rm -f "$domains" "$tmp" "$oldcache"; fail "collect"; }
    if [ -s "$cache" ]; then
        awk 'NF>=4 { print $1 "\t" $2 "\t" $3 "\t" $4 }' "$cache" | sort -u > "$oldcache" || {
            rm -f "$domains" "$tmp" "$oldcache"
            fail "old"
        }
    else
        : > "$oldcache"
    fi

    now="$(date +%s)"
    exec 7< "$oldcache"
    read -r old_domain old_ip old_status old_time <&7 || old_domain=""
    while IFS= read -r domain || [ -n "$domain" ]; do
        [ -n "$domain" ] || continue
        while [ -n "${old_domain:-}" ] && [[ "$old_domain" < "$domain" ]]; do
            read -r old_domain old_ip old_status old_time <&7 || old_domain=""
        done
        if [ "${old_domain:-}" != "$domain" ]; then
            old_ip=""; old_status=""; old_time=""
        fi
        if ip="$(resolve_ipv4 "$domain")"; then
            write_cache_line "$domain" "$ip" ok "$now" "$old_ip" "$old_status" "$old_time" >> "$tmp"
        else
            validate_ipv4 "$old_ip" || old_ip="-"
            write_cache_line "$domain" "$old_ip" failed "$now" "$old_ip" "$old_status" "$old_time" >> "$tmp"
        fi
    done < "$domains"
    sort -u "$tmp" -o "$tmp"

    if cmp -s "$tmp" "$cache" 2>/dev/null; then
        rm -f "$domains" "$tmp" "$oldcache"
        command -v flock >/dev/null 2>&1 && { flock -u 8 2>/dev/null || true; exec 8>&-; }
        log "unchanged"
        return 0
    fi

    mv "$tmp" "$cache" || { rm -f "$domains" "$tmp" "$oldcache"; fail "install"; }
    rm -f "$domains" "$oldcache"
    changed=1
    command -v flock >/dev/null 2>&1 && { flock -u 8 2>/dev/null || true; exec 8>&-; }
    log "updated"
    [ "$run_hooks" != "1" ] || [ "$changed" -ne 1 ] || run_hooks
}

systemctl_cmd() {
    command -v systemctl 2>/dev/null
}

write_if_changed() {
    local tmp="$1" target="$2"
    if cmp -s "$tmp" "$target" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$target" || { rm -f "$tmp"; fail "write $target"; }
    chmod 644 "$target" 2>/dev/null || true
    return 0
}

install_units() {
    local service timer script tmp changed=0 systemctl
    require_root
    service="$(service_file)"
    timer="$(timer_file)"
    script="$(script_path)"
    mkdir -p "$(systemd_dir)" || fail "systemd dir"

    tmp="${service}.tmp.$$"
    cat > "$tmp" << EOF || fail "service"
[Unit]
Description=Provider DNS refresh service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash "${script}" --refresh hooks
EOF
    write_if_changed "$tmp" "$service" && changed=1

    tmp="${timer}.tmp.$$"
    cat > "$tmp" << 'EOF' || fail "timer"
[Unit]
Description=Provider DNS refresh timer

[Timer]
OnBootSec=30s
OnUnitActiveSec=10min
AccuracySec=5s
Unit=providerdns.service

[Install]
WantedBy=timers.target
EOF
    write_if_changed "$tmp" "$timer" && changed=1

    [ "$ROOT" != "/" ] && { log "install: ready"; return 0; }
    systemctl="$(systemctl_cmd || true)"
    [ -n "$systemctl" ] || { log "install: systemctl skipped"; return 0; }
    [ "$changed" = "0" ] || "$systemctl" daemon-reload >/dev/null 2>&1 || fail "daemon reload"
    "$systemctl" enable --now providerdns.timer >/dev/null 2>&1 || fail "timer enable"
    log "install: enabled"
}

has_subscriptions() {
    local dir file
    dir="$(subscription_dir)"
    [ -d "$dir" ] || return 1
    for file in "$dir"/*.list; do
        [ -s "$file" ] && return 0
    done
    return 1
}

cleanup_unused() {
    local systemctl
    require_root
    has_subscriptions && { log "cleanup: subscriptions exist"; return 0; }
    if [ "$ROOT" = "/" ]; then
        systemctl="$(systemctl_cmd || true)"
        [ -z "$systemctl" ] || "$systemctl" disable --now providerdns.timer >/dev/null 2>&1 || true
        [ -z "$systemctl" ] || "$systemctl" stop providerdns.service >/dev/null 2>&1 || true
        [ -z "$systemctl" ] || "$systemctl" reset-failed providerdns.timer providerdns.service >/dev/null 2>&1 || true
    fi
    rm -f "$(service_file)" "$(timer_file)" "$(cache_file)"
    rmdir "$(state_dir)" "$(hook_dir)" "$(subscription_dir)" "$(path "/etc/provider/dns")" 2>/dev/null || true
    log "cleanup: done"
}

lookup_domain() {
    local domain="$1" ip
    validate_domain "$domain" || fail "domain"
    if ip="$(cache_ip "$domain")"; then
        printf '%s\n' "$ip"
        return 0
    fi
    resolve_ipv4 "$domain"
}

show_help() {
    cat << 'EOF'
Usage:
  providerdns.sh --api
  providerdns.sh --install
  providerdns.sh --refresh
  providerdns.sh --refresh hooks
  providerdns.sh --lookup example.com
  providerdns.sh --cleanup unused
EOF
}

main() {
    local action="${1:-}" mode="${2:-}"
    case "$action" in
        --api) printf '%s\n' "$API_VERSION" ;;
        --install) install_units ;;
        --refresh)
            case "$mode" in
                "") refresh_cache 0 ;;
                hooks) refresh_cache 1 ;;
                *) fail "refresh mode" ;;
            esac
            ;;
        --lookup)
            [ -n "${2:-}" ] || fail "lookup domain"
            lookup_domain "$2"
            ;;
        --cleanup)
            [ "$mode" = "unused" ] || fail "cleanup mode"
            cleanup_unused
            ;;
        --help|-h|"") show_help; [ -n "$action" ]; exit $? ;;
        *) fail "action" ;;
    esac
}

main "$@"
