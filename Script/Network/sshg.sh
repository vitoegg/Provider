#!/bin/bash

set -o pipefail

ROOT="${SSHG_ROOT:-/}"
ROOT_PREFIX="${ROOT%/}"
NFT_TABLE="sshg"
PROVIDERDNS_BIN="${PROVIDERDNS_BIN:-}"
PROVIDERDNS_CONSUMER="sshg"
SSH_CONFIG_CHANGED=0
SSHG_TRANSACTION_DIR=""
SSHG_TRANSACTION_DNS=0
SSHG_NFT_TOUCHED=0
SSHD_DROPIN="${ROOT_PREFIX}/etc/ssh/sshd_config.d/00-sshg.conf"
KEY_FILE="${ROOT_PREFIX}/root/.ssh/authorized_keys3"
STATE_DIR="${ROOT_PREFIX}/etc/sshg"
ALLOW_IPV4_FILE="${ROOT_PREFIX}/etc/sshg/allow.ipv4"
ALLOW_DOMAIN_FILE="${ROOT_PREFIX}/etc/sshg/allow.domain"
NFT_FILE="${ROOT_PREFIX}/etc/nftables.d/sshg.nft"
NFT_MAIN_FILE="${ROOT_PREFIX}/etc/nftables.conf"
SSHG_TRANSACTION_TARGETS=(
    "$ALLOW_IPV4_FILE" "$ALLOW_DOMAIN_FILE" "$NFT_FILE"
    "$NFT_MAIN_FILE" "$KEY_FILE" "$SSHD_DROPIN"
)

log_info() {
    [ "${SSHG_QUIET:-${QUIET:-0}}" = "1" ] || printf '[INFO] %s\n' "$*"
}

log_warning() {
    printf '[WARNING] %s\n' "$*" >&2
}

log_error() {
    printf '[ERROR] %s\n' "$*" >&2
}

fail() {
    if [ -n "$SSHG_TRANSACTION_DIR" ]; then
        rollback_transaction
    fi
    log_error "$*"
    exit 1
}

trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

require_root() {
    [ "$ROOT" != "/" ] && return 0
    [ "$(id -u)" = "0" ] || fail "此操作必须以 root 权限运行"
}

ensure_sshg_dependencies() {
    local missing=()
    command -v apt-get >/dev/null 2>&1 || fail "仅支持使用 apt-get 的 Debian 类系统"
    nft_cmd >/dev/null 2>&1 || missing+=(nftables)
    sshd_cmd >/dev/null 2>&1 || missing+=(openssh-server)
    command -v flock >/dev/null 2>&1 || missing+=(util-linux)
    [ "${#missing[@]}" -eq 0 ] && return 0
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || fail "apt-get update 失败"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1 ||
        fail "依赖安装失败：${missing[*]}"
    nft_cmd >/dev/null 2>&1 || fail "安装 nftables 后仍未检测到 nft"
    sshd_cmd >/dev/null 2>&1 || fail "安装 openssh-server 后仍未检测到 sshd"
    command -v flock >/dev/null 2>&1 || fail "安装 util-linux 后仍未检测到 flock"
    log_info "已安装依赖：${missing[*]}"
}

acquire_lock() {
    mkdir -p "${ROOT_PREFIX}/run/sshg" || fail "无法创建锁目录"
    exec 9>"${ROOT_PREFIX}/run/sshg/lock" || fail "无法创建锁文件"
    command -v flock >/dev/null 2>&1 || fail "缺少依赖命令：flock"
    flock -n 9 || fail "检测到其他任务正在执行中，请稍后重试"
}

command_path() {
    local env_value="$1" command_name="$2" resolved
    if [ -n "$env_value" ]; then
        [ -x "$env_value" ] || return 1
        printf '%s\n' "$env_value"
        return 0
    fi
    resolved="$(command -v "$command_name" 2>/dev/null || true)"
    [ -n "$resolved" ] || return 1
    printf '%s\n' "$resolved"
}

sshd_cmd() {
    if command_path "${SSHG_SSHD:-}" sshd; then
        return 0
    fi
    [ -x /usr/sbin/sshd ] || return 1
    printf '%s\n' /usr/sbin/sshd
}

nft_cmd() {
    command_path "${SSHG_NFT:-}" nft
}

systemctl_cmd() {
    command_path "${SSHG_SYSTEMCTL:-}" systemctl
}

begin_transaction() {
    local include_allow="$1" index target transaction_dir
    transaction_dir="$(
        umask 077
        mktemp -d "${TMPDIR:-/tmp}/sshg-transaction.XXXXXX"
    )" ||
        fail "无法创建事务快照目录"
    if [ -d "$STATE_DIR" ] && ! : > "${transaction_dir}/state-dir"; then
        rm -rf "$transaction_dir"
        fail "无法记录事务状态目录"
    fi
    for index in "${!SSHG_TRANSACTION_TARGETS[@]}"; do
        target="${SSHG_TRANSACTION_TARGETS[$index]}"
        [ -e "$target" ] || [ -L "$target" ] || continue
        if ! cp -Pp "$target" "${transaction_dir}/${index}"; then
            rm -rf "$transaction_dir"
            fail "无法创建事务快照：$target"
        fi
    done
    SSHG_TRANSACTION_DIR="$transaction_dir"
    SSHG_TRANSACTION_DNS="$include_allow"
}

rollback_live_nft() {
    local nft
    nft="$(nft_cmd 2>/dev/null || true)"
    [ -n "$nft" ] || return 1
    if [ -s "$NFT_FILE" ]; then
        "$nft" -f "$NFT_FILE" >/dev/null 2>&1
        return
    fi
    "$nft" delete table inet "$NFT_TABLE" >/dev/null 2>&1
}

rollback_transaction() {
    local index target snapshot failed=0
    [ -n "$SSHG_TRANSACTION_DIR" ] || return 0
    for index in "${!SSHG_TRANSACTION_TARGETS[@]}"; do
        target="${SSHG_TRANSACTION_TARGETS[$index]}"
        snapshot="${SSHG_TRANSACTION_DIR}/${index}"
        if ! rm -f "$target"; then
            failed=1
            continue
        fi
        [ -e "$snapshot" ] || [ -L "$snapshot" ] || continue
        if ! mkdir -p "$(dirname "$target")" || ! cp -Pp "$snapshot" "$target"; then
            failed=1
        fi
    done
    if [ ! -e "${SSHG_TRANSACTION_DIR}/state-dir" ]; then
        rmdir "$STATE_DIR" 2>/dev/null || true
    fi
    if [ "$SSHG_NFT_TOUCHED" = "1" ] && ! rollback_live_nft; then
        failed=1
    fi
    if [ "$SSHG_TRANSACTION_DNS" = "1" ] && ! reconcile_sshg_dns >/dev/null 2>&1; then
        failed=1
    fi
    rm -rf "$SSHG_TRANSACTION_DIR"
    SSHG_TRANSACTION_DIR=""
    [ "$failed" = "0" ] || log_error "事务回滚未完全成功，请检查 SSH、nftables 与 ProviderDNS 状态"
}

commit_transaction() {
    rm -rf "$SSHG_TRANSACTION_DIR" || log_warning "无法清理事务快照：$SSHG_TRANSACTION_DIR"
    SSHG_TRANSACTION_DIR=""
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

ipv4_to_24_cidr() {
    local ip="$1"
    validate_ipv4 "$ip" || return 1
    printf '%s.0/24\n' "${ip%.*}"
}

validate_cidr() {
    local value="$1" ip prefix
    case "$value" in
        */*)
            ip="${value%/*}"
            prefix="${value#*/}"
            validate_ipv4 "$ip" || return 1
            [[ "$prefix" =~ ^[0-9]+$ ]] && [ "$prefix" -ge 0 ] && [ "$prefix" -le 32 ]
            ;;
        *)
            validate_ipv4 "$value"
            ;;
    esac
}

validate_domain() {
    local domain="$1"
    [ -n "$domain" ] && [ "${#domain}" -le 253 ] &&
        [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\
([.][A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}

public_key_id() {
    local key="$1" key_type key_body
    case "$key" in
        *'
'*)
            return 1
            ;;
    esac
    read -r key_type key_body _ <<< "$key"
    [ "$key_type" = "ssh-ed25519" ] || return 1
    [[ "$key_body" =~ ^[A-Za-z0-9+/=]+$ ]] || return 1
    printf '%s %s\n' "$key_type" "$key_body"
}

key_file_has_key() {
    local file="$1" target="${2:-}" line value
    [ -s "$file" ] || return 1
    if [ -n "$target" ]; then
        target="$(public_key_id "$target")" || return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        value="$(public_key_id "$(trim "${line%%#*}")" 2>/dev/null || true)"
        [ -n "$value" ] || continue
        if [ -z "$target" ] || [ "$value" = "$target" ]; then
            return 0
        fi
    done < "$file"
    return 1
}

write_key() {
    local key="$1" file tmp existed=0
    [ -n "$key" ] || return 0
    key="$(trim "$key")"
    public_key_id "$key" >/dev/null || fail "SSH 公钥格式无效"
    file="$KEY_FILE"
    key_file_has_key "$file" "$key" && return 0
    root_key_exists "$key" 0 && return 0
    if [ -e "$file" ] || [ -L "$file" ]; then
        existed=1
    fi
    mkdir -p "$(dirname "$file")" || fail "无法创建密钥目录"
    tmp="$(mktemp "${file}.XXXXXX")" || fail "无法创建托管密钥临时文件"
    chmod 700 "$(dirname "$file")" 2>/dev/null || true
    printf '%s\n' "$key" > "$tmp" || fail "无法写入托管密钥"
    chmod 600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$file" || fail "无法安装托管密钥"
    if [ "$existed" = "1" ]; then
        log_info "已更新托管密钥"
    else
        log_info "已添加托管密钥"
    fi
}

remove_key() {
    [ -e "$KEY_FILE" ] || [ -L "$KEY_FILE" ] || return 0
    rm -f "$KEY_FILE" || fail "无法删除托管密钥"
    log_info "已删除托管密钥"
}

root_key_exists() {
    local key="${1:-}" include_managed="${2:-1}" file
    local -a files=("${ROOT_PREFIX}/root/.ssh/authorized_keys" "${ROOT_PREFIX}/root/.ssh/authorized_keys2")
    [ "$include_managed" = "0" ] || files+=("$KEY_FILE")
    for file in "${files[@]}"; do
        key_file_has_key "$file" "$key" && return 0
    done
    return 1
}

sshd_has_dropin_include() {
    [ "$ROOT" != "/" ] && return 0
    [ -f "${ROOT_PREFIX}/etc/ssh/sshd_config" ] || return 1
    grep -Eiq '^[[:space:]]*Include[[:space:]]+"?/etc/ssh/sshd_config\.d/\*\.conf"?([[:space:]]|$)' \
        "${ROOT_PREFIX}/etc/ssh/sshd_config"
}

sshd_effective_config_ok() {
    local effective
    effective="$("$1" -T 2>/dev/null)" || return 1
    awk '
        {
            key = $1
            $1 = ""
            sub(/^[[:space:]]+/, "")
            value[key] = $0
        }
        END {
            root = value["permitrootlogin"]
            if (root == "without-password") {
                root = "prohibit-password"
            }
            valid = value["passwordauthentication"] == "no" &&
                value["kbdinteractiveauthentication"] == "no" &&
                value["pubkeyauthentication"] == "yes" && root == "prohibit-password" &&
                value["maxauthtries"] == "3" && value["maxstartups"] == "10:30:60" &&
                value["authorizedkeysfile"] == ".ssh/authorized_keys .ssh/authorized_keys2 .ssh/authorized_keys3"
            exit(valid ? 0 : 1)
        }
    ' <<< "$effective"
}

write_ssh_config() {
    local file tmp sshd
    SSH_CONFIG_CHANGED=0
    sshd_has_dropin_include || fail "sshd_config 未包含 /etc/ssh/sshd_config.d/*.conf"
    sshd="$(sshd_cmd)" || fail "未检测到 sshd"
    mkdir -p "${ROOT_PREFIX}/run/sshd" 2>/dev/null || true
    file="$SSHD_DROPIN"
    mkdir -p "$(dirname "$file")" || fail "无法创建 SSH 配置目录"
    tmp="$(mktemp "${file}.XXXXXX")" || fail "无法创建 SSH 配置临时文件"
    cat > "$tmp" << 'EOF' || fail "无法写入 SSH 配置"
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
MaxAuthTries 3
MaxStartups 10:30:60
AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2 .ssh/authorized_keys3
EOF
    if cmp -s "$tmp" "$file"; then
        rm -f "$tmp"
    else
        mv "$tmp" "$file" || fail "无法安装 SSH 配置"
        SSH_CONFIG_CHANGED=1
    fi
    "$sshd" -t >/dev/null 2>&1 || fail "SSH 配置预检失败"
    sshd_effective_config_ok "$sshd" || fail "SSH 生效配置不符合预期"
    if [ "$SSH_CONFIG_CHANGED" = "1" ]; then
        log_info "SSH 配置已应用"
    fi
}

remove_ssh_config() {
    SSH_CONFIG_CHANGED=0
    [ -e "$SSHD_DROPIN" ] || [ -L "$SSHD_DROPIN" ] || return 0
    rm -f "$SSHD_DROPIN" || fail "无法删除 SSH 配置"
    SSH_CONFIG_CHANGED=1
    log_info "SSH 配置已删除"
}

reload_ssh() {
    local systemctl unit
    [ "$ROOT" != "/" ] && [ -z "${SSHG_SYSTEMCTL:-}" ] && return 0
    systemctl="$(systemctl_cmd 2>/dev/null || true)"
    [ -n "$systemctl" ] || fail "未检测到 systemctl，无法重载 SSH"
    for unit in ssh.service sshd.service; do
        "$systemctl" is-active --quiet "$unit" >/dev/null 2>&1 || continue
        "$systemctl" reload "$unit" >/dev/null 2>&1 || fail "SSH 重载失败：$unit"
        log_info "SSH 已重载：$unit"
        return 0
    done
    fail "SSH 服务未运行，请执行：systemctl status ssh.service sshd.service"
}

append_allow_values() {
    local values="$1" ipv4_output="$2" domain_output="$3" value
    while IFS= read -r value || [ -n "$value" ]; do
        value="$(trim "$value")"
        [ -n "$value" ] || continue
        if validate_cidr "$value"; then
            printf '%s\n' "$value" >> "$ipv4_output"
        elif validate_domain "$value"; then
            printf '%s\n' "$value" >> "$domain_output"
        else
            fail "白名单格式无效: $value"
        fi
    done < <(printf '%s' "$values" | tr ',' '\n')
}

build_allow_candidates() {
    local mode="$1" values="$2" ipv4_output="$3" domain_output="$4"
    : > "$ipv4_output" || fail "无法写入 IPv4 白名单"
    : > "$domain_output" || fail "无法写入域名白名单"
    if [ "$mode" != "reset" ]; then
        if [ -s "$ALLOW_IPV4_FILE" ]; then
            cat "$ALLOW_IPV4_FILE" >> "$ipv4_output" || fail "无法读取 IPv4 白名单"
        fi
        if [ -s "$ALLOW_DOMAIN_FILE" ]; then
            cat "$ALLOW_DOMAIN_FILE" >> "$domain_output" || fail "无法读取域名白名单"
        fi
    fi
    if [ "$mode" != "sync" ] && [ -n "$values" ]; then
        append_allow_values "$values" "$ipv4_output" "$domain_output"
    fi
    sort -u "$ipv4_output" -o "$ipv4_output"
    sort -u "$domain_output" -o "$domain_output"
    [ -s "$ipv4_output" ] || [ -s "$domain_output" ] || fail "白名单为空"
}

run_providerdns() {
    local bin="$PROVIDERDNS_BIN"
    if [ -z "$bin" ]; then
        bin="$(dirname "$(realpath "$0")")/providerdns.sh"
    fi
    [ -f "$bin" ] || return 2
    PROVIDERDNS_ROOT="$ROOT" /bin/bash "$bin" "$@"
}

providerdns_set_sshg() {
    local domains_file="$1" script quoted_script hook_command
    script="$(realpath "$0")"
    printf -v quoted_script '%q' "$script"
    hook_command="SSHG_QUIET=1 /bin/bash ${quoted_script} hook"
    run_providerdns --set "$PROVIDERDNS_CONSUMER" "$domains_file" "$hook_command" >/dev/null 2>&1
}

providerdns_unset_sshg() {
    run_providerdns --unset "$PROVIDERDNS_CONSUMER" >/dev/null 2>&1
}

build_sources_file() {
    local output="$1" ipv4_input="$2" domain_input="$3" value record ip
    [ -s "$ipv4_input" ] || [ -s "$domain_input" ] || fail "白名单为空"
    : > "$output" || fail "无法写入放行来源"
    if [ -s "$ipv4_input" ]; then
        while IFS= read -r value || [ -n "$value" ]; do
            value="$(trim "$value")"
            [ -n "$value" ] || continue
            validate_cidr "$value" || fail "IPv4 白名单格式无效: $value"
            printf '%s\n' "$value" >> "$output"
        done < "$ipv4_input"
    fi
    if [ -s "$domain_input" ]; then
        while IFS= read -r value || [ -n "$value" ]; do
            value="$(trim "$value")"
            [ -n "$value" ] || continue
            validate_domain "$value" || fail "域名白名单格式无效: $value"
            record="$(run_providerdns --cache "$value" 2>/dev/null || true)"
            ip="$(awk '{ print $2 }' <<< "$record")"
            if validate_ipv4 "$ip"; then
                ipv4_to_24_cidr "$ip" >> "$output"
            else
                log_warning "域名解析失败，已跳过：$value"
            fi
        done < "$domain_input"
    fi
    sort -u "$output" -o "$output"
    [ -s "$output" ] || fail "放行来源为空"
}

detect_ssh_ports() {
    local sshd effective ports port
    local -a port_arr
    if [ -n "${SSHG_PORTS:-}" ]; then
        IFS=',' read -ra port_arr <<< "$SSHG_PORTS"
        for port in "${port_arr[@]}"; do
            [[ "$port" =~ ^[0-9]+$ ]] || return 1
            if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
                return 1
            fi
        done
        printf '%s\n' "$SSHG_PORTS"
        return 0
    fi
    sshd="$(sshd_cmd)" || return 1
    if ! effective="$("$sshd" -T 2>/dev/null)"; then
        log_error "无法读取 SSH 生效配置，拒绝应用防火墙规则"
        return 1
    fi
    ports="$(printf '%s\n' "$effective" |
        awk '$1 == "port" && $2 ~ /^[0-9]+$/ && $2 >= 1 && $2 <= 65535 { print $2 }' |
        sort -un | tr '\n' ',' | sed 's/,$//')"
    if [ -z "$ports" ]; then
        log_error "SSH 生效配置未包含有效端口，拒绝应用防火墙规则"
        return 1
    fi
    printf '%s\n' "$ports"
}

render_nft() {
    local sources="$1" output="$2" ports="$3" first=1 source
    cat > "$output" << EOF || fail "无法生成 NFT 规则"
#!/usr/sbin/nft -f
# generated by sshg.sh

table inet ${NFT_TABLE}
delete table inet ${NFT_TABLE}

table inet ${NFT_TABLE} {
    set allowed_ipv4 {
        type ipv4_addr
        flags interval
        elements = {
EOF
    while IFS= read -r source; do
        [ -n "$source" ] || continue
        if [ "$first" = "1" ]; then
            printf '            %s' "$source" >> "$output"
            first=0
        else
            printf ',\n            %s' "$source" >> "$output"
        fi
    done < "$sources"
    cat >> "$output" << EOF || fail "无法生成 NFT 规则"

        }
    }

    chain input {
        type filter hook input priority -20; policy accept;
        ct state established,related accept
        iifname "lo" accept
        meta nfproto ipv4 tcp dport { ${ports} } ip saddr @allowed_ipv4 accept
        meta nfproto ipv4 tcp dport { ${ports} } drop
        meta nfproto ipv6 tcp dport { ${ports} } drop
    }
}
EOF
}

ensure_nft_include() {
    local tmp
    if grep -Eq '^[[:space:]]*include[[:space:]]+"?/etc/nftables\.d/(\*|sshg)\.nft"?[[:space:]]*$' \
        "$NFT_MAIN_FILE" 2>/dev/null; then
        return 0
    fi
    mkdir -p "$(dirname "$NFT_MAIN_FILE")" || return 1
    tmp="$(mktemp "${NFT_MAIN_FILE}.XXXXXX")" || return 1
    if [ -e "$NFT_MAIN_FILE" ]; then
        if ! cp -p "$NFT_MAIN_FILE" "$tmp"; then
            rm -f "$tmp"
            return 1
        fi
    else
        chmod 644 "$tmp" 2>/dev/null || true
    fi
    if ! printf '\n%s\ninclude "/etc/nftables.d/*.nft"\n' '# Managed by Provider sshg.sh' >> "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv "$tmp" "$NFT_MAIN_FILE"; then
        rm -f "$tmp"
        return 1
    fi
    log_info "已写入 nftables include：$NFT_MAIN_FILE"
}

ensure_nft_service() {
    local systemctl
    [ "$ROOT" != "/" ] && [ -z "${SSHG_SYSTEMCTL:-}" ] && return 0
    systemctl="$(systemctl_cmd 2>/dev/null || true)"
    [ -n "$systemctl" ] || return 0
    if "$systemctl" is-enabled --quiet nftables.service >/dev/null 2>&1; then
        return 0
    fi
    if "$systemctl" enable nftables.service >/dev/null 2>&1; then
        log_info "已启用系统服务：nftables.service"
    else
        log_warning "无法启用 nftables.service，重启后规则可能丢失"
    fi
}

state_file_matches() {
    local candidate="$1" current="$2"
    if [ -s "$candidate" ]; then
        cmp -s "$candidate" "$current"
    else
        [ ! -s "$current" ]
    fi
}

publish_state_file() {
    local candidate="$1" target="$2" tmp
    if [ ! -s "$candidate" ]; then
        rm -f "$target" || return 1
        return 0
    fi
    tmp="$(mktemp "${target}.XXXXXX")" || return 1
    if ! cp "$candidate" "$tmp" || ! chmod 600 "$tmp" || ! mv "$tmp" "$target"; then
        rm -f "$tmp"
        return 1
    fi
}

apply_nft_from_files() {
    local ipv4_input="$1" domain_input="$2" commit_allow="${3:-0}"
    local nft tmp sources ports source_count allow_unchanged=0
    nft="$(nft_cmd)" || fail "未检测到 nft"
    mkdir -p "$(dirname "$NFT_FILE")" || fail "无法创建 NFT 规则目录"
    tmp="$(mktemp "${NFT_FILE}.XXXXXX")" || fail "无法创建 NFT 规则临时文件"
    if ! sources="$(mktemp "${NFT_FILE}.sources.XXXXXX")"; then
        rm -f "$tmp"
        fail "无法创建放行来源临时文件"
    fi
    build_sources_file "$sources" "$ipv4_input" "$domain_input"
    ports="$(detect_ssh_ports)" || fail "无法检测 SSH 端口"
    render_nft "$sources" "$tmp" "$ports"
    if ! "$nft" -c -f "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp" "$sources"
        fail "NFT 规则预检失败"
    fi
    ensure_nft_include || fail "无法写入 nftables include"
    ensure_nft_service
    source_count="$(wc -l < "$sources" | tr -d ' ')"
    if [ "$commit_allow" = "0" ]; then
        allow_unchanged=1
    elif state_file_matches "$ipv4_input" "$ALLOW_IPV4_FILE" &&
        state_file_matches "$domain_input" "$ALLOW_DOMAIN_FILE"; then
        allow_unchanged=1
    fi
    if [ "$allow_unchanged" = "1" ] && cmp -s "$tmp" "$NFT_FILE" 2>/dev/null &&
        "$nft" list table inet "$NFT_TABLE" >/dev/null 2>&1; then
        rm -f "$tmp" "$sources"
        log_info "SSH 防火墙规则未变化，无需重新应用"
        return 0
    fi
    if [ "$commit_allow" = "1" ]; then
        mkdir -p "$STATE_DIR" || fail "无法创建状态目录"
        publish_state_file "$ipv4_input" "$ALLOW_IPV4_FILE" || fail "IPv4 白名单提交失败"
        publish_state_file "$domain_input" "$ALLOW_DOMAIN_FILE" || fail "域名白名单提交失败"
    fi
    if ! mv "$tmp" "$NFT_FILE"; then
        rm -f "$sources"
        fail "无法安装 NFT 规则"
    fi
    chmod 600 "$NFT_FILE" 2>/dev/null || true
    SSHG_NFT_TOUCHED=1
    if ! "$nft" -f "$NFT_FILE" >/dev/null 2>&1 ||
        ! "$nft" list table inet "$NFT_TABLE" >/dev/null 2>&1; then
        rm -f "$sources"
        fail "NFT 规则应用失败"
    fi
    rm -f "$sources"
    log_info "SSH 防火墙规则已应用：端口 ${ports}，放行来源 ${source_count} 个"
}

reconcile_sshg_dns() {
    local rc
    if [ -s "$ALLOW_DOMAIN_FILE" ]; then
        providerdns_set_sshg "$ALLOW_DOMAIN_FILE" >/dev/null 2>&1
    else
        providerdns_unset_sshg >/dev/null 2>&1
    fi
    rc=$?
    [ "$rc" = "0" ] || [ "$rc" = "2" ]
}

sync_rules_from_candidates() {
    local ipv4_candidate="$1" domain_candidate="$2" rc
    if [ -s "$domain_candidate" ]; then
        if ! providerdns_set_sshg "$domain_candidate" ||
            ! PROVIDERDNS_LOCK_WAIT="${PROVIDERDNS_LOCK_WAIT:-10}" \
                run_providerdns --refresh >/dev/null 2>&1; then
            fail "域名刷新失败"
        fi
    fi
    apply_nft_from_files "$ipv4_candidate" "$domain_candidate" "1"
    if [ ! -s "$domain_candidate" ]; then
        providerdns_unset_sshg
        rc=$?
        [ "$rc" = "0" ] || [ "$rc" = "2" ] || fail "无法取消 Provider DNS 注册"
    fi
}

update_allow_state() {
    local mode="$1" values="$2" ipv4_candidate domain_candidate
    ipv4_candidate="$(mktemp /tmp/sshg-allow-ipv4.XXXXXX)" || fail "无法创建 IPv4 白名单临时文件"
    if ! domain_candidate="$(mktemp /tmp/sshg-allow-domain.XXXXXX)"; then
        rm -f "$ipv4_candidate"
        fail "无法创建域名白名单临时文件"
    fi
    build_allow_candidates "$mode" "$values" "$ipv4_candidate" "$domain_candidate"
    sync_rules_from_candidates "$ipv4_candidate" "$domain_candidate"
    rm -f "$ipv4_candidate" "$domain_candidate"
}

apply_cached_rules() {
    [ -s "$ALLOW_IPV4_FILE" ] || [ -s "$ALLOW_DOMAIN_FILE" ] || fail "白名单为空"
    apply_nft_from_files "$ALLOW_IPV4_FILE" "$ALLOW_DOMAIN_FILE" 0
}

clear_allow_state() {
    local changed=0 rc
    [ ! -e "$ALLOW_IPV4_FILE" ] || changed=1
    [ ! -e "$ALLOW_DOMAIN_FILE" ] || changed=1
    [ ! -e "$NFT_FILE" ] || changed=1
    remove_active_nft
    rm -f "$ALLOW_IPV4_FILE" "$ALLOW_DOMAIN_FILE" "$NFT_FILE" || fail "无法清理 SSH 白名单"
    rmdir "$STATE_DIR" 2>/dev/null || true
    providerdns_unset_sshg
    rc=$?
    [ "$rc" = "0" ] || [ "$rc" = "2" ] || fail "无法取消 Provider DNS 注册"
    [ "$changed" = "0" ] || log_info "SSH 白名单已清空"
}

remove_active_nft() {
    local nft tmp
    nft="$(nft_cmd 2>/dev/null || true)"
    [ -n "$nft" ] || fail "未检测到 nft，无法验证 live NFT table 已清理"
    "$nft" list table inet "$NFT_TABLE" >/dev/null 2>&1 || return 0
    tmp="$(mktemp /tmp/sshg-clean.XXXXXX)" || fail "无法创建 NFT 清理临时文件"
    cat > "$tmp" << EOF
table inet ${NFT_TABLE}
delete table inet ${NFT_TABLE}
EOF
    SSHG_NFT_TOUCHED=1
    if ! "$nft" -f "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        fail "live NFT table 清理失败"
    fi
    rm -f "$tmp"
    "$nft" list table inet "$NFT_TABLE" >/dev/null 2>&1 && fail "live NFT table 清理后仍然存在"
    log_info "已删除 live NFT table：${NFT_TABLE}"
}

remove_path_report() {
    local target="$1" label="$2"
    [ -e "$target" ] || [ -L "$target" ] || return 0
    rm -rf "$target" || fail "无法删除${label}：$target"
    log_info "已删除${label}：$target"
}

sshg_resources_exist() {
    local nft
    if [[ -e "$SSHD_DROPIN" || -L "$SSHD_DROPIN" || -e "$KEY_FILE" || -L "$KEY_FILE" ||
        -e "$NFT_FILE" || -L "$NFT_FILE" || -d "$STATE_DIR" ]]; then
        return 0
    fi
    nft="$(nft_cmd 2>/dev/null || true)"
    [ -n "$nft" ] || return 1
    "$nft" list table inet "$NFT_TABLE" >/dev/null 2>&1
}

remove_all() {
    local rc ssh_changed=0
    if ! sshg_resources_exist; then
        reconcile_sshg_dns || fail "无法取消 Provider DNS 注册"
        log_info "SSH 防护已不存在，无需移除"
        return 0
    fi
    remove_active_nft
    if [ -e "$SSHD_DROPIN" ] || [ -L "$SSHD_DROPIN" ]; then
        ssh_changed=1
    fi
    remove_path_report "$SSHD_DROPIN" "SSH 配置"
    remove_path_report "$KEY_FILE" "托管 root 公钥"
    remove_path_report "$NFT_FILE" "NFT 持久规则"
    remove_path_report "$STATE_DIR" "sshg 业务状态目录"
    if providerdns_unset_sshg; then
        log_info "已取消 Provider DNS 注册：${PROVIDERDNS_CONSUMER}"
    else
        rc=$?
        [ "$rc" = "2" ] || fail "无法取消 Provider DNS 注册"
    fi
    [ "$ssh_changed" = "0" ] || reload_ssh
    log_info "SSH 防护已移除"
}

show_help() {
    cat << 'EOF'
用法：
  sshg.sh --apply config=ssh allow=1.2.3.4,1.2.3.0/24,example.com key='ssh-ed25519 AAAA...'
  sshg.sh --reset config=ssh allow=1.2.3.4,example.com key='ssh-ed25519 AAAA...'
  sshg.sh --sync
  sshg.sh --remove

动作：
  --apply        合并指定的 SSH 配置、公钥和白名单
  --reset        重置目标状态；未指定的配置、公钥或白名单会被移除
  --sync         重新解析域名并刷新 nftables 规则
  --remove       移除 sshg 托管文件和 nftables 表

参数：
  config=ssh     应用 SSH 加固配置
  key=...        写入 root 使用的 ssh-ed25519 公钥
  allow=...      逗号分隔的 IPv4、IPv4 CIDR 或域名

兼容入口：apply、reset、sync、remove；hook 仅供 ProviderDNS 回调使用。
EOF
}

main() {
    local action="" raw_action="${1:-}" allow_values="" key_value="" config_value="" arg
    local allow_seen=0 key_seen=0 config_seen=0 transaction_allow=1
    case "$raw_action" in
        --apply|--reset|--sync|--remove)
            action="${raw_action#--}"
            shift
            ;;
        apply|reset|sync|remove|hook)
            action="$raw_action"
            shift
            ;;
        help|-h|--help)
            shift
            [ "$#" -eq 0 ] || fail "帮助参数后不允许附加内容"
            show_help
            return 0
            ;;
        "")
            show_help
            return 1
            ;;
        *)
            fail "未知操作：$raw_action"
            ;;
    esac

    if [[ "$action" =~ ^(sync|remove|hook)$ ]]; then
        [ "$#" -eq 0 ] || fail "动作 ${raw_action} 不接受参数"
    fi

    while [ "$#" -gt 0 ]; do
        arg="$1"
        case "$arg" in
            allow=*)
                allow_seen=1
                allow_values="${allow_values}${allow_values:+,}${arg#allow=}"
                ;;
            key=*)
                key_seen=1
                key_value="${arg#key=}"
                ;;
            config=*)
                config_seen=1
                config_value="${arg#config=}"
                ;;
            *)
                fail "未知参数: $arg"
                ;;
        esac
        shift
    done

    if [ "$action" = "apply" ] || [ "$action" = "reset" ]; then
        [ "$config_seen" = "0" ] || [ "$config_value" = "ssh" ] || fail "配置参数无效"
        if [ "$key_seen" = "1" ]; then
            public_key_id "$(trim "$key_value")" >/dev/null || fail "SSH 公钥格式无效"
        fi
        if [ "$config_seen" = "1" ] && [ "$key_seen" = "0" ]; then
            if [ "$action" = "reset" ]; then
                root_key_exists "" 0 || fail "未检测到 root SSH 公钥"
            else
                root_key_exists || fail "未检测到 root SSH 公钥"
            fi
        fi
    fi
    if [ "$action" = "apply" ] && [ "$allow_seen$key_seen$config_seen" = "000" ]; then
        fail "没有需要执行的操作"
    fi
    require_root
    [[ "$action" =~ ^(apply|reset|sync)$ ]] && ensure_sshg_dependencies
    acquire_lock
    if [ "$action" = "apply" ]; then
        transaction_allow="$allow_seen"
    elif [ "$action" = "hook" ]; then
        transaction_allow=0
    fi
    begin_transaction "$transaction_allow"
    case "$action" in
        apply|reset)
            if [ "$allow_seen" = "1" ]; then
                update_allow_state "$action" "$allow_values"
            elif [ "$action" = "reset" ]; then
                clear_allow_state
            fi
            if [ "$key_seen" = "1" ]; then
                write_key "$key_value"
            elif [ "$action" = "reset" ]; then
                remove_key
            fi
            if [ "$config_seen" = "1" ]; then
                root_key_exists || fail "未检测到 root SSH 公钥"
                write_ssh_config
            elif [ "$action" = "reset" ]; then
                remove_ssh_config
            fi
            [ "$SSH_CONFIG_CHANGED" = "0" ] || reload_ssh
            ;;
        sync)
            update_allow_state "sync" ""
            ;;
        hook)
            SSHG_QUIET=1
            apply_cached_rules
            ;;
        remove)
            remove_all
            ;;
    esac
    commit_transaction
}

main "$@"
