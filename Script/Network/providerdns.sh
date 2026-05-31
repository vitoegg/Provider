#!/bin/bash

# PROVIDERDNS_MANAGED=1

set -o pipefail

ROOT="${PROVIDERDNS_ROOT:-/}"
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

path_in_git_worktree() {
    command -v git >/dev/null 2>&1 || return 1
    git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

remove_self_after_install() {
    local current_path="$1" current_dir
    [ -f "$current_path" ] || return 0
    current_dir="$(cd "$(dirname "$current_path")" 2>/dev/null && pwd)" || return 0
    path_in_git_worktree "$current_dir" && return 0
    rm -f "$current_path" 2>/dev/null || true
}

require_root() {
    [ "$ROOT" != "/" ] && return 0
    [ "$(id -u)" = "0" ] || fail "need root"
}

ensure_self_at_fixed_location() {
    local current_path target_path tmp_path
    
    # 禁用 ROOT 环境下的自我安置（容器/chroot 场景）
    [ "$ROOT" != "/" ] && return 0
    
    current_path="$(script_path)"
    target_path="/usr/local/sbin/providerdns.sh"
    
    # 已在正确位置，无需处理
    if [ "$current_path" = "$target_path" ]; then
        return 0
    fi
    
    # 验证当前脚本合法性
    if ! bash -n "$current_path" 2>/dev/null; then
        log "self-placement: syntax check failed"
        return 1
    fi
    
    # 目标已是最新时，只清理启动源文件
    if [ -f "$target_path" ] && cmp -s "$current_path" "$target_path" 2>/dev/null; then
        log "self-placement: target already current"
        remove_self_after_install "$current_path"
        return 0
    fi
    
    # 原子写入：使用临时文件 + 重命名
    tmp_path="${target_path}.tmp.$$"
    if ! cp "$current_path" "$tmp_path" 2>/dev/null; then
        log "self-placement: copy to temp failed"
        return 1
    fi
    
    if ! mv "$tmp_path" "$target_path" 2>/dev/null; then
        rm -f "$tmp_path" 2>/dev/null || true
        log "self-placement: move to target failed"
        return 1
    fi
    
    chmod 755 "$target_path" 2>/dev/null || true
    log "self-placement: installed at $target_path"
    
    # 删除原文件（已安全复制）
    remove_self_after_install "$current_path"
    
    return 0
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

validate_consumer() {
    local consumer="$1"
    [ -n "$consumer" ] && [[ "$consumer" =~ ^[A-Za-z0-9._-]+$ ]]
}

consumer_subscription_file() { path "/etc/provider/dns/subscriptions/$1.list"; }
consumer_hook_file() { path "/etc/provider/dns/hooks/$1"; }

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

cache_record() {
    local domain="$1" file
    validate_domain "$domain" || return 1
    file="$(cache_file)"
    [ -s "$file" ] || return 1
    awk -v d="$domain" '$1==d && NF>=4 { print $1 "\t" $2 "\t" $3 "\t" $4; found=1; exit } END { exit(found ? 0 : 1) }' "$file"
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

consumer_has_changed_domain() {
    local subscription="$1" changed="$2"
    [ -s "$changed" ] || return 1
    [ -s "$subscription" ] || return 0
    awk 'NR==FNR { changed[$1]=1; next } $1 in changed { found=1; exit } END { exit(found ? 0 : 1) }' "$changed" "$subscription"
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
    local changed="${1:-}" dir hook name subscription failed=0
    dir="$(hook_dir)"
    [ -d "$dir" ] || return 0
    for hook in "$dir"/*; do
        [ -x "$hook" ] || continue
        if [ -n "$changed" ]; then
            name="$(basename "$hook")"
            subscription="$(consumer_subscription_file "$name")"
            consumer_has_changed_domain "$subscription" "$changed" || continue
        fi
        "$hook" || failed=$((failed + 1))
    done
    [ "$failed" -eq 0 ] || { log "hookfail=${failed}"; return 1; }
}

refresh_cache() {
    local run_hooks="${1:-0}" lock_wait="${PROVIDERDNS_LOCK_WAIT:-0}" domains tmp oldcache changed_domains cache domain old_domain now ip old_ip old_status old_time changed=0 new_ip new_status hook_rc=0
    mkdir -p "$(subscription_dir)" "$(hook_dir)" "$(state_dir)" || fail "dir"
    if command -v flock >/dev/null 2>&1; then
        exec 8>"$(lock_file)" || fail "lock"
        if [[ "$lock_wait" =~ ^[0-9]+$ ]] && [ "$lock_wait" -gt 0 ]; then
            flock -w "$lock_wait" 8 || { log "locked"; return 75; }
        else
            flock -n 8 || { log "locked"; return 0; }
        fi
    fi

    domains="$(mktemp /tmp/providerdns-domains.XXXXXX)" || fail "temp"
    tmp="$(mktemp /tmp/providerdns-cache.XXXXXX)" || { rm -f "$domains"; fail "temp"; }
    oldcache="$(mktemp /tmp/providerdns-old.XXXXXX)" || { rm -f "$domains" "$tmp"; fail "temp"; }
    changed_domains="$(mktemp /tmp/providerdns-changed.XXXXXX)" || { rm -f "$domains" "$tmp" "$oldcache"; fail "temp"; }
    cache="$(cache_file)"

    collect_domains "$domains" || { rm -f "$domains" "$tmp" "$oldcache" "$changed_domains"; fail "collect"; }
    if [ -s "$cache" ]; then
        awk 'NF>=4 { print $1 "\t" $2 "\t" $3 "\t" $4 }' "$cache" | sort -u > "$oldcache" || {
            rm -f "$domains" "$tmp" "$oldcache" "$changed_domains"
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
            new_ip="$ip"; new_status="ok"
        else
            validate_ipv4 "$old_ip" || old_ip="-"
            new_ip="$old_ip"; new_status="failed"
        fi
        write_cache_line "$domain" "$new_ip" "$new_status" "$now" "$old_ip" "$old_status" "$old_time" >> "$tmp"
        [ "$new_ip" = "$old_ip" ] && [ "$new_status" = "$old_status" ] || printf '%s\n' "$domain" >> "$changed_domains"
    done < "$domains"
    sort -u "$tmp" -o "$tmp"
    sort -u "$changed_domains" -o "$changed_domains"

    if cmp -s "$tmp" "$cache" 2>/dev/null; then
        rm -f "$domains" "$tmp" "$oldcache" "$changed_domains"
        command -v flock >/dev/null 2>&1 && { flock -u 8 2>/dev/null || true; exec 8>&-; }
        log "unchanged"
        return 0
    fi

    mv "$tmp" "$cache" || { rm -f "$domains" "$tmp" "$oldcache" "$changed_domains"; fail "install"; }
    rm -f "$domains" "$oldcache"
    changed=1
    command -v flock >/dev/null 2>&1 && { flock -u 8 2>/dev/null || true; exec 8>&-; }
    log "updated"
    if [ "$run_hooks" = "1" ] && [ "$changed" -eq 1 ]; then
        run_hooks "$changed_domains" || hook_rc=1
    fi
    rm -f "$changed_domains"
    return "$hook_rc"
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
    ensure_self_at_fixed_location
    service="$(service_file)"
    timer="$(timer_file)"
    script="/usr/local/sbin/providerdns.sh"
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
OnActiveSec=30s
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

set_consumer() {
    local consumer="$1" domains_file="$2" hook_command="$3" subscription hook tmp
    require_root
    validate_consumer "$consumer" || fail "consumer"
    [ -f "$domains_file" ] || fail "domains"
    [ -n "$hook_command" ] || fail "hook"
    mkdir -p "$(subscription_dir)" "$(hook_dir)" || fail "dir"
    subscription="$(consumer_subscription_file "$consumer")"
    hook="$(consumer_hook_file "$consumer")"
    tmp="${subscription}.tmp.$$"
    : > "$tmp" || fail "subscription"
    while IFS= read -r domain || [ -n "$domain" ]; do
        domain="$(trim "${domain%%#*}")"
        [ -n "$domain" ] || continue
        validate_domain "$domain" || fail "domain $domain"
        printf '%s\n' "$domain" >> "$tmp"
    done < "$domains_file"
    sort -u "$tmp" -o "$tmp"
    if [ -s "$tmp" ]; then
        mv "$tmp" "$subscription" || { rm -f "$tmp"; fail "subscription"; }
        chmod 644 "$subscription" 2>/dev/null || true
        {
            printf '%s\n' '#!/bin/bash'
            printf '%s\n' "$hook_command"
        } > "$hook" || fail "hook"
        chmod 755 "$hook" || fail "hook mode"
        install_units
        log "set: $consumer"
    else
        rm -f "$tmp" "$subscription" "$hook"
        cleanup_unused
        log "unset: $consumer"
    fi
}

unset_consumer() {
    local consumer="$1"
    require_root
    validate_consumer "$consumer" || fail "consumer"
    rm -f "$(consumer_subscription_file "$consumer")" "$(consumer_hook_file "$consumer")"
    cleanup_unused
    log "unset: $consumer"
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
  providerdns.sh --install
  providerdns.sh --set <consumer> <domain-file> <hook-command>
  providerdns.sh --unset <consumer>
  providerdns.sh --refresh
  providerdns.sh --refresh hooks
  providerdns.sh --cache <domain>
  providerdns.sh --lookup example.com
  providerdns.sh --cleanup unused
EOF
}

main() {
    local action="${1:-}" mode="${2:-}"
    case "$action" in
        --install) install_units ;;
        --set)
            [ $# -ge 4 ] || fail "set args"
            action="$2"
            mode="$3"
            shift 3
            set_consumer "$action" "$mode" "$*"
            ;;
        --unset)
            [ -n "$mode" ] || fail "unset consumer"
            unset_consumer "$mode"
            ;;
        --refresh)
            case "$mode" in
                "") refresh_cache 0 ;;
                hooks) refresh_cache 1 ;;
                *) fail "refresh mode" ;;
            esac
            ;;
        --cache)
            [ -n "${2:-}" ] || fail "cache domain"
            cache_record "$2"
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
