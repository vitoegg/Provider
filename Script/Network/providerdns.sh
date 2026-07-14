#!/bin/bash

# PROVIDERDNS_MANAGED=1

set -o pipefail

ROOT="${PROVIDERDNS_ROOT:-/}"
TEMP_FILES=()
ROOT_PREFIX="${ROOT%/}"
SUBSCRIPTION_DIR="${ROOT_PREFIX}/etc/provider/dns/subscriptions"
HOOK_DIR="${ROOT_PREFIX}/etc/provider/dns/hooks"
STATE_DIR="${ROOT_PREFIX}/var/lib/provider/dns"
CACHE_FILE="${ROOT_PREFIX}/var/lib/provider/dns/cache.tsv"
LOCK_FILE="${ROOT_PREFIX}/run/providerdns.lock"
SERVICE_FILE="${ROOT_PREFIX}/etc/systemd/system/providerdns.service"
TIMER_FILE="${ROOT_PREFIX}/etc/systemd/system/providerdns.timer"

log_info() {
    [ "${PROVIDERDNS_QUIET:-0}" = "1" ] || printf '[INFO] %s\n' "$*"
}

log_error() {
    printf '[ERROR] %s\n' "$*" >&2
}

fail() {
    log_error "$*"
    exit 1
}

trap 'rm -f "${TEMP_FILES[@]}"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

show_help() {
    cat << 'EOF'
用法：
  providerdns.sh --install
  providerdns.sh --set <consumer> <域名文件> <hook 命令>
  providerdns.sh --unset <consumer>
  providerdns.sh --refresh
  providerdns.sh --refresh hooks
  providerdns.sh --cache <域名>
  providerdns.sh --lookup <域名>
  providerdns.sh --cleanup unused
  providerdns.sh -h|--help
EOF
}

trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

validate_ipv4() {
    local ip="$1" octet
    local -a octets
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -ra octets <<< "$ip"
    [ "${#octets[@]}" -eq 4 ] || return 1
    for octet in "${octets[@]}"; do
        [ "$octet" -le 255 ] || return 1
    done
}

validate_domain() {
    local domain="$1"
    [ -n "$domain" ] && [ "${#domain}" -le 253 ] &&
        [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\
([.][A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}

require_root() {
    [ "$ROOT" != "/" ] && return 0
    [ "$(id -u)" = "0" ] || fail "此操作必须以 root 权限运行"
}

ensure_private_dir() {
    mkdir -p "$1" || return 1
    chmod 700 "$1" || return 1
}

require_resolver() {
    [ -n "${PROVIDERDNS_HOSTS_FILE:-}" ] && return 0
    command -v getent >/dev/null 2>&1 || fail "缺少依赖命令：getent"
    command -v timeout >/dev/null 2>&1 || fail "缺少依赖命令：timeout"
    [[ "${PROVIDERDNS_TIMEOUT:-5}" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "DNS 超时参数无效"
}

cache_ip() {
    local ip
    [ -s "$CACHE_FILE" ] || return 1
    ip="$(awk -v d="$1" '$1==d { print $2; exit }' "$CACHE_FILE")"
    validate_ipv4 "$ip" || return 1
    printf '%s\n' "$ip"
}

cache_record() {
    validate_domain "$1" || return 1
    [ -s "$CACHE_FILE" ] || return 1
    awk -v d="$1" '
        $1 == d && NF >= 4 {
            print $1 "\t" $2 "\t" $3 "\t" $4
            found = 1
            exit
        }
        END { exit(found ? 0 : 1) }
    ' "$CACHE_FILE"
}

resolve_ipv4() {
    local domain="$1" ip timeout_value
    if [ -n "${PROVIDERDNS_HOSTS_FILE:-}" ]; then
        ip="$(awk -v d="$domain" '$1==d { print $2; exit }' "$PROVIDERDNS_HOSTS_FILE")"
    else
        timeout_value="${PROVIDERDNS_TIMEOUT:-5}"
        ip="$(timeout "${timeout_value}s" getent ahostsv4 "$domain" 2>/dev/null | awk '/STREAM/ { print $1; exit }')"
    fi
    validate_ipv4 "$ip" || return 1
    printf '%s\n' "$ip"
}

collect_domains() {
    local output="$1" file line domain
    ensure_private_dir "$SUBSCRIPTION_DIR" || return 1
    : > "$output" || return 1
    for file in "$SUBSCRIPTION_DIR"/*.list; do
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

run_hooks() {
    local changed="${1:-}" hook name subscription failed=0
    [ -d "$HOOK_DIR" ] || return 0
    for hook in "$HOOK_DIR"/*; do
        [ -x "$hook" ] || continue
        if [ -n "$changed" ]; then
            name="$(basename "$hook")"
            subscription="${SUBSCRIPTION_DIR}/${name}.list"
            [ -s "$changed" ] || continue
            [ -s "$subscription" ] || continue
            grep -Fqx -f "$changed" "$subscription" || continue
        fi
        "$hook" || failed=$((failed + 1))
    done
    if [ "$failed" -ne 0 ]; then
        log_error "Provider DNS hook 执行失败：${failed} 个"
        return 1
    fi
}

acquire_lock() {
    local wait="${1:-0}"
    command -v flock >/dev/null 2>&1 || fail "缺少依赖命令：flock"
    mkdir -p "$(dirname "$LOCK_FILE")" || fail "无法创建 Provider DNS 锁目录"
    exec 8>"$LOCK_FILE" || fail "无法创建 Provider DNS 锁文件"
    chmod 600 "$LOCK_FILE" 2>/dev/null || true
    if [[ "$wait" =~ ^[0-9]+$ ]] && [ "$wait" -gt 0 ]; then
        flock -w "$wait" 8
    else
        flock -n 8
    fi
}

release_lock() {
    flock -u 8 2>/dev/null || true
    exec 8>&-
}

refresh_cache() {
    local run_hooks="${1:-0}" lock_wait="${PROVIDERDNS_LOCK_WAIT:-0}"
    local domains tmp changed_domains domain now ip
    local old_ip old_status old_time new_ip new_status updated_at
    require_resolver
    ensure_private_dir "$HOOK_DIR" || fail "无法创建 Provider DNS 运行目录"
    ensure_private_dir "$STATE_DIR" || fail "无法创建 Provider DNS 运行目录"
    if ! acquire_lock "$lock_wait"; then
        log_error "已有 Provider DNS 任务正在执行，请稍后重试"
        return 75
    fi

    domains="$(mktemp /tmp/providerdns-domains.XXXXXX)" || fail "无法创建域名临时文件"
    TEMP_FILES+=("$domains")
    tmp="$(mktemp "${CACHE_FILE}.XXXXXX")" || fail "无法创建缓存临时文件"
    TEMP_FILES+=("$tmp")
    changed_domains="$(mktemp /tmp/providerdns-changed.XXXXXX)" || fail "无法创建变更域名临时文件"
    TEMP_FILES+=("$changed_domains")

    collect_domains "$domains" || fail "无法收集 Provider DNS 订阅域名"
    now="$(date +%s)"
    while IFS= read -r domain || [ -n "$domain" ]; do
        [ -n "$domain" ] || continue
        old_ip=""
        old_status=""
        old_time=""
        if [ -s "$CACHE_FILE" ]; then
            IFS=$'\t' read -r old_ip old_status old_time < <(
                awk -v d="$domain" '$1 == d { print $2 "\t" $3 "\t" $4; exit }' "$CACHE_FILE"
            )
        fi
        if ip="$(resolve_ipv4 "$domain")"; then
            new_ip="$ip"
            new_status="ok"
        else
            validate_ipv4 "$old_ip" || old_ip="-"
            new_ip="$old_ip"
            new_status="failed"
        fi
        updated_at="$now"
        if [ "$old_ip" = "$new_ip" ] && [ "$old_status" = "$new_status" ] && [ -n "$old_time" ]; then
            updated_at="$old_time"
        fi
        printf '%s\t%s\t%s\t%s\n' "$domain" "$new_ip" "$new_status" "$updated_at" >> "$tmp"
        if [ "$new_ip" != "$old_ip" ] || [ "$new_status" != "$old_status" ]; then
            printf '%s\n' "$domain" >> "$changed_domains"
        fi
    done < "$domains"
    if cmp -s "$tmp" "$CACHE_FILE" 2>/dev/null; then
        release_lock
        log_info "Provider DNS 缓存未变化，无需更新"
        return 0
    fi

    chmod 600 "$tmp" || fail "无法设置 DNS 缓存权限"
    mv "$tmp" "$CACHE_FILE" || fail "无法发布 Provider DNS 缓存"
    release_lock
    log_info "Provider DNS 缓存已更新"
    if [ "$run_hooks" = "1" ]; then
        run_hooks "$changed_domains"
    fi
}

write_if_changed() {
    local tmp="$1" target="$2"
    if cmp -s "$tmp" "$target" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$target" || fail "无法写入文件：$target"
}

install_units() {
    local script tmp changed=0
    require_root
    if [ "$ROOT" = "/" ] && ! command -v systemctl >/dev/null 2>&1; then
        fail "未检测到 systemctl，无法安装 Provider DNS timer"
    fi
    script="$(realpath "$0")"
    mkdir -p "$(dirname "$SERVICE_FILE")" || fail "无法创建 systemd 配置目录"

    tmp="$(mktemp "${SERVICE_FILE}.XXXXXX")" || fail "无法创建 systemd service 临时文件"
    TEMP_FILES+=("$tmp")
    cat > "$tmp" << EOF || fail "无法生成 Provider DNS service"
[Unit]
Description=Provider DNS refresh service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=PROVIDERDNS_QUIET=1
Environment=PROVIDERDNS_LOCK_WAIT=10
ExecStart=/bin/bash "${script}" --refresh hooks
EOF
    write_if_changed "$tmp" "$SERVICE_FILE" && changed=1

    tmp="$(mktemp "${TIMER_FILE}.XXXXXX")" || fail "无法创建 systemd timer 临时文件"
    TEMP_FILES+=("$tmp")
    cat > "$tmp" << 'EOF' || fail "无法生成 Provider DNS timer"
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
    write_if_changed "$tmp" "$TIMER_FILE" && changed=1
    chmod 644 "$SERVICE_FILE" "$TIMER_FILE" || fail "无法设置 systemd unit 权限"

    [ "$ROOT" != "/" ] && return 0
    [ "$changed" = "0" ] || systemctl daemon-reload >/dev/null 2>&1 || fail "systemd daemon-reload 失败"
    if systemctl is-enabled --quiet providerdns.timer >/dev/null 2>&1 &&
        systemctl is-active --quiet providerdns.timer >/dev/null 2>&1; then
        return 0
    fi
    if ! systemctl enable --now --no-reload providerdns.timer >/dev/null 2>&1 ||
       ! systemctl is-active --quiet providerdns.timer >/dev/null 2>&1; then
        fail "Provider DNS timer 启用失败"
    fi
    log_info "已启用系统服务：providerdns.timer"
}

set_consumer() {
    local consumer="$1" domains_file="$2" hook_command="$3" subscription hook subscription_tmp hook_tmp changed=0
    require_root
    [[ "$consumer" =~ ^[A-Za-z0-9._-]+$ ]] || fail "consumer 名称无效"
    [ -f "$domains_file" ] || fail "订阅文件不存在：$domains_file"
    [ -n "$hook_command" ] || fail "hook 命令为空"
    ensure_private_dir "$SUBSCRIPTION_DIR" || fail "无法创建 Provider DNS 配置目录"
    ensure_private_dir "$HOOK_DIR" || fail "无法创建 Provider DNS 配置目录"
    acquire_lock "${PROVIDERDNS_LOCK_WAIT:-10}" || fail "已有 Provider DNS 任务正在执行，请稍后重试"
    subscription="${SUBSCRIPTION_DIR}/${consumer}.list"
    hook="${HOOK_DIR}/${consumer}"
    subscription_tmp="$(mktemp "${subscription}.XXXXXX")" || fail "无法创建订阅临时文件"
    hook_tmp="$(mktemp "${hook}.XXXXXX")" || fail "无法创建 hook 临时文件"
    TEMP_FILES+=("$subscription_tmp" "$hook_tmp")
    : > "$subscription_tmp" || fail "无法生成订阅"
    while IFS= read -r domain || [ -n "$domain" ]; do
        domain="$(trim "${domain%%#*}")"
        [ -n "$domain" ] || continue
        validate_domain "$domain" || fail "域名无效：$domain"
        printf '%s\n' "$domain" >> "$subscription_tmp"
    done < "$domains_file"
    sort -u "$subscription_tmp" -o "$subscription_tmp"
    if [ -s "$subscription_tmp" ]; then
        {
            printf '%s\n' '#!/bin/bash'
            printf '%s\n' "$hook_command"
        } > "$hook_tmp" || fail "无法生成 hook"
        write_if_changed "$hook_tmp" "$hook" && changed=1
        write_if_changed "$subscription_tmp" "$subscription" && changed=1
        chmod 700 "$hook" || fail "无法设置 hook 权限"
        chmod 600 "$subscription" || fail "无法设置订阅权限"
        install_units
        release_lock
        if [ "$changed" = "1" ]; then
            log_info "Provider DNS consumer 已更新：$consumer"
        else
            log_info "Provider DNS consumer 未变化：$consumer"
        fi
    else
        rm -f "$subscription_tmp" "$hook_tmp" "$subscription" "$hook"
        cleanup_unused_locked
        release_lock
        log_info "Provider DNS consumer 已取消：$consumer"
    fi
}

unset_consumer() {
    local consumer="$1" subscription hook existed=0
    require_root
    [[ "$consumer" =~ ^[A-Za-z0-9._-]+$ ]] || fail "consumer 名称无效"
    acquire_lock "${PROVIDERDNS_LOCK_WAIT:-10}" || fail "已有 Provider DNS 任务正在执行，请稍后重试"
    subscription="${SUBSCRIPTION_DIR}/${consumer}.list"
    hook="${HOOK_DIR}/${consumer}"
    [ ! -e "$subscription" ] || existed=1
    [ ! -e "$hook" ] || existed=1
    rm -f "$subscription" "$hook" || fail "无法取消 Provider DNS consumer：$consumer"
    cleanup_unused_locked
    release_lock
    if [ "$existed" = "1" ]; then
        log_info "Provider DNS consumer 已取消：$consumer"
    else
        log_info "Provider DNS consumer 已不存在：$consumer"
    fi
}

cleanup_unused_locked() {
    local systemctl file changed=0
    if [ -d "$SUBSCRIPTION_DIR" ]; then
        for file in "$SUBSCRIPTION_DIR"/*.list; do
            [ -s "$file" ] && return 0
        done
    fi
    [[ -e "$SERVICE_FILE" || -e "$TIMER_FILE" || -d "$STATE_DIR" || -d "$HOOK_DIR" ||
        -d "$SUBSCRIPTION_DIR" ]] && changed=1
    if [ "$ROOT" = "/" ]; then
        systemctl="$(command -v systemctl 2>/dev/null || true)"
        [ -n "$systemctl" ] || fail "未检测到 systemctl，无法清理 Provider DNS runtime"
        if "$systemctl" is-enabled --quiet providerdns.timer >/dev/null 2>&1 ||
            "$systemctl" is-active --quiet providerdns.timer >/dev/null 2>&1; then
            "$systemctl" disable --now --no-reload providerdns.timer >/dev/null 2>&1 ||
                fail "Provider DNS timer 停用失败"
            log_info "已停止并禁用系统服务：providerdns.timer"
            changed=1
        fi
        if "$systemctl" is-active --quiet providerdns.service >/dev/null 2>&1; then
            "$systemctl" stop providerdns.service >/dev/null 2>&1 ||
                fail "Provider DNS service 停止失败"
            log_info "已停止系统服务：providerdns.service"
            changed=1
        fi
        if [ "$changed" = "1" ]; then
            "$systemctl" reset-failed providerdns.timer providerdns.service >/dev/null 2>&1 || true
        fi
    fi
    rm -f "$SERVICE_FILE" "$TIMER_FILE" || fail "Provider DNS 运行时清理失败"
    rm -rf "$STATE_DIR" "$HOOK_DIR" "$SUBSCRIPTION_DIR" || fail "Provider DNS 运行时清理失败"
    rmdir "${ROOT_PREFIX}/etc/provider/dns" 2>/dev/null || true
    if [ "$ROOT" = "/" ] && [ "$changed" = "1" ] && [ -n "${systemctl:-}" ]; then
        "$systemctl" daemon-reload >/dev/null 2>&1 || fail "systemd daemon-reload 失败"
    fi
    if [ "$changed" = "1" ]; then
        log_info "Provider DNS 运行时已清理"
    else
        log_info "Provider DNS 运行时已不存在，无需清理"
    fi
}

main() {
    local action="${1:-}" mode="${2:-}"
    case "$action" in
        --install)
            [ "$#" -eq 1 ] || fail "--install 不支持额外参数"
            install_units
            ;;
        --set)
            [ $# -ge 4 ] || fail "--set 缺少 consumer、域名文件或 hook 命令"
            action="$2"
            mode="$3"
            shift 3
            set_consumer "$action" "$mode" "$*"
            ;;
        --unset)
            [ "$#" -eq 2 ] || fail "--unset 需要且仅需要 consumer"
            unset_consumer "$mode"
            ;;
        --refresh)
            case "$mode" in
                "")
                    [ "$#" -eq 1 ] || fail "--refresh 不支持额外参数"
                    refresh_cache 0
                    ;;
                hooks)
                    [ "$#" -eq 2 ] || fail "--refresh hooks 不支持额外参数"
                    refresh_cache 1
                    ;;
                *)
                    fail "refresh 模式无效：$mode"
                    ;;
            esac
            ;;
        --cache)
            [ "$#" -eq 2 ] || fail "--cache 需要且仅需要域名"
            cache_record "$2"
            ;;
        --lookup)
            [ "$#" -eq 2 ] || fail "--lookup 需要且仅需要域名"
            validate_domain "$2" || fail "域名无效：$2"
            if ! cache_ip "$2"; then
                require_resolver
                resolve_ipv4 "$2"
            fi
            ;;
        --cleanup)
            if [ "$#" -ne 2 ] || [ "$mode" != "unused" ]; then
                fail "cleanup 模式无效"
            fi
            require_root
            acquire_lock "${PROVIDERDNS_LOCK_WAIT:-10}" ||
                fail "已有 Provider DNS 任务正在执行，请稍后重试"
            cleanup_unused_locked
            release_lock
            ;;
        --help|-h)
            [ "$#" -eq 1 ] || fail "帮助参数不支持额外参数"
            show_help
            ;;
        "")
            show_help
            exit 1
            ;;
        *)
            fail "未知操作：$action"
            ;;
    esac
}

main "$@"
