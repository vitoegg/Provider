#!/bin/bash

set -o pipefail

ROOT="${SSHG_ROOT:-/}"
NFT_TABLE="sshg"
PROVIDERDNS_BIN="${PROVIDERDNS_BIN:-/usr/local/sbin/providerdns.sh}"
PROVIDERDNS_LOCAL_NAME="providerdns.sh"
PROVIDERDNS_CONSUMER="sshg"
SSHG_LOCK_HELD=0
SSHG_DNS_ROLLBACK_ON_FAIL=0

log_info() { [ "${SSHG_QUIET:-0}" = "1" ] || printf '[INFO] %s\n' "$*"; }
log_warn() { printf '[WARNING] %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

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

require_root() {
    [ "$ROOT" != "/" ] && return 0
    [ "$(id -u)" = "0" ] || fail "此操作必须以 root 权限运行"
}

acquire_lock() {
    local lock
    [ "$SSHG_LOCK_HELD" = "1" ] && return 0
    lock="$(sshg_lock_file)"
    mkdir -p "$(dirname "$lock")" || fail "无法创建锁目录"
    exec 9>"$lock" || fail "无法创建锁文件"
    if command -v flock >/dev/null 2>&1; then
        flock -n 9 || fail "检测到其他任务正在执行中，请稍后重试"
    fi
    SSHG_LOCK_HELD=1
}

command_path() {
    local env_value="$1" command_name="$2" resolved
    [ -n "$env_value" ] && { printf '%s\n' "$env_value"; return 0; }
    resolved="$(command -v "$command_name" 2>/dev/null || true)"
    [ -n "$resolved" ] || return 1
    printf '%s\n' "$resolved"
}

sshd_cmd() {
    command_path "${SSHG_SSHD:-}" sshd || {
        [ -x /usr/sbin/sshd ] && { printf '%s\n' /usr/sbin/sshd; return 0; }
        return 1
    }
}

nft_cmd() {
    command_path "${SSHG_NFT:-}" nft
}

systemctl_cmd() {
    command_path "${SSHG_SYSTEMCTL:-}" systemctl
}

sshd_config() { path "/etc/ssh/sshd_config"; }
sshd_dropin() { path "/etc/ssh/sshd_config.d/00-sshg.conf"; }
key_file() { path "/root/.ssh/authorized_keys3"; }
state_dir() { path "/etc/sshg"; }
allow_ipv4_file() { path "/etc/sshg/allow.ipv4"; }
allow_domain_file() { path "/etc/sshg/allow.domain"; }
nft_file() { path "/etc/nftables.d/sshg.nft"; }
nft_main_file() { path "/etc/nftables.conf"; }
sshg_lock_file() { path "/run/sshg/lock"; }

validate_ipv4() {
    local ip="$1" a b c d old_ifs
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    old_ifs="$IFS"; IFS=.; set -- $ip; IFS="$old_ifs"
    [ "$#" -eq 4 ] || return 1
    for a in "$@"; do
        [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge 0 ] && [ "$a" -le 255 ] || return 1
    done
}

ipv4_to_24_cidr() {
    local ip="$1" old_ifs
    validate_ipv4 "$ip" || return 1
    old_ifs="$IFS"; IFS=.; set -- $ip; IFS="$old_ifs"
    printf '%s.%s.%s.0/24\n' "$1" "$2" "$3"
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
        [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?([.][A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}

public_key_valid() {
    local key="$1" type body
    case "$key" in
        *'
'*) return 1 ;;
    esac
    set -- $key
    type="${1:-}"
    body="${2:-}"
    case "$type" in
        ssh-ed25519|ssh-rsa|ecdsa-sha2-*|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) ;;
        *) return 1 ;;
    esac
    [ -n "$body" ] && [[ "$body" =~ ^[A-Za-z0-9+/=]+$ ]]
}

write_key() {
    local key="$1" file tmp
    [ -n "$key" ] || return 0
    key="$(trim "$key")"
    public_key_valid "$key" || fail "SSH 公钥格式无效"
    file="$(key_file)"
    tmp="${file}.tmp.$$"
    mkdir -p "$(dirname "$file")" || fail "无法创建密钥目录"
    chmod 700 "$(dirname "$file")" 2>/dev/null || true
    printf '%s\n' "$key" > "$tmp" || fail "无法写入托管密钥"
    chmod 600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$file" || fail "无法安装托管密钥"
    log_info "已写入托管密钥"
}

remove_key() {
    rm -f "$(key_file)" || fail "无法删除托管密钥"
    log_info "已删除托管密钥"
}

root_key_exists() {
    local file line value
    for file in "$(path "/root/.ssh/authorized_keys")" "$(path "/root/.ssh/authorized_keys2")" "$(key_file)"; do
        [ -s "$file" ] || continue
        while IFS= read -r line || [ -n "$line" ]; do
            value="$(trim "${line%%#*}")"
            [ -n "$value" ] || continue
            public_key_valid "$value" && return 0
        done < "$file"
    done
    return 1
}

root_key_exists_without_managed() {
    local file line value
    for file in "$(path "/root/.ssh/authorized_keys")" "$(path "/root/.ssh/authorized_keys2")"; do
        [ -s "$file" ] || continue
        while IFS= read -r line || [ -n "$line" ]; do
            value="$(trim "${line%%#*}")"
            [ -n "$value" ] || continue
            public_key_valid "$value" && return 0
        done < "$file"
    done
    return 1
}

sshd_has_dropin_include() {
    local config
    [ "$ROOT" != "/" ] && return 0
    config="$(sshd_config)"
    [ -f "$config" ] || return 1
    grep -Eiq '^[[:space:]]*Include[[:space:]]+"?/etc/ssh/sshd_config\.d/\*\.conf"?([[:space:]]|$)' "$config"
}

ensure_sshd_runtime() {
    mkdir -p "$(path "/run/sshd")" 2>/dev/null || true
}

normalize_sshd_value() {
    case "$1:$2" in
        permitrootlogin:without-password) printf 'prohibit-password\n' ;;
        *) printf '%s\n' "$2" ;;
    esac
}

effective_sshd_value() {
    local file="$1" key="$2"
    awk -v k="$key" '$1==k { $1=""; sub(/^[[:space:]]+/, ""); print; exit }' "$file"
}

expect_sshd_value() {
    local file="$1" key="$2" expected="$3" actual
    actual="$(effective_sshd_value "$file" "$key")"
    [ "$(normalize_sshd_value "$key" "$actual")" = "$expected" ]
}

sshd_effective_config_ok() {
    local sshd="$1" effective
    effective="$(mktemp /tmp/sshg-sshd.XXXXXX)" || return 1
    "$sshd" -T > "$effective" 2>/dev/null || { rm -f "$effective"; return 1; }
    expect_sshd_value "$effective" passwordauthentication no &&
        expect_sshd_value "$effective" kbdinteractiveauthentication no &&
        expect_sshd_value "$effective" pubkeyauthentication yes &&
        expect_sshd_value "$effective" permitrootlogin prohibit-password &&
        expect_sshd_value "$effective" maxauthtries 3 &&
        expect_sshd_value "$effective" maxstartups '10:30:60' &&
        expect_sshd_value "$effective" authorizedkeysfile '.ssh/authorized_keys .ssh/authorized_keys2 .ssh/authorized_keys3'
    local result=$?
    rm -f "$effective"
    return "$result"
}

write_ssh_config() {
    local file tmp backup had_old=0 sshd
    sshd_has_dropin_include || fail "sshd_config 未包含 /etc/ssh/sshd_config.d/*.conf"
    sshd="$(sshd_cmd)" || fail "未检测到 sshd"
    ensure_sshd_runtime
    file="$(sshd_dropin)"
    tmp="${file}.tmp.$$"
    backup="${file}.bak.$$"
    mkdir -p "$(dirname "$file")" || fail "无法创建 SSH 配置目录"
    cat > "$tmp" << 'EOF' || fail "无法写入 SSH 配置"
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
MaxAuthTries 3
MaxStartups 10:30:60
AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2 .ssh/authorized_keys3
EOF
    if [ -f "$file" ]; then
        cp "$file" "$backup" || fail "无法备份 SSH 配置"
        had_old=1
    fi
    mv "$tmp" "$file" || fail "无法安装 SSH 配置"
    if ! "$sshd" -t >/dev/null 2>&1; then
        if [ "$had_old" = "1" ]; then
            mv "$backup" "$file" 2>/dev/null || true
        else
            rm -f "$file"
        fi
        fail "SSH 配置预检失败"
    fi
    if ! sshd_effective_config_ok "$sshd"; then
        if [ "$had_old" = "1" ]; then
            mv "$backup" "$file" 2>/dev/null || true
        else
            rm -f "$file"
        fi
        fail "SSH 生效配置不符合预期"
    fi
    rm -f "$backup"
    log_info "SSH 配置已应用"
}

remove_ssh_config() {
    rm -f "$(sshd_dropin)" || fail "无法删除 SSH 配置"
    log_info "SSH 配置已删除"
}

reload_ssh() {
    local systemctl unit
    [ "$ROOT" != "/" ] && return 0
    systemctl="$(systemctl_cmd 2>/dev/null || true)"
    if [ -n "$systemctl" ]; then
        for unit in ssh.service sshd.service; do
            "$systemctl" is-active --quiet "$unit" >/dev/null 2>&1 || continue
            "$systemctl" reload "$unit" >/dev/null 2>&1 && { log_info "SSH 已重载: $unit"; return 0; }
        done
        "$systemctl" reload ssh.service >/dev/null 2>&1 && { log_info "SSH 已重载: ssh.service"; return 0; }
        "$systemctl" reload sshd.service >/dev/null 2>&1 && { log_info "SSH 已重载: sshd.service"; return 0; }
    fi
    if command -v service >/dev/null 2>&1; then
        service ssh reload >/dev/null 2>&1 && { log_info "SSH 已重载: service ssh"; return 0; }
        service sshd reload >/dev/null 2>&1 && { log_info "SSH 已重载: service sshd"; return 0; }
    fi
    pkill -HUP -x sshd >/dev/null 2>&1 && { log_info "SSH 已重载: HUP"; return 0; }
    fail "SSH 重载失败"
}

append_allow_values() {
    local values="$1" ipv4_output="$2" domain_output="$3" value
    printf '%s' "$values" | tr ',' '\n' | while IFS= read -r value || [ -n "$value" ]; do
        value="$(trim "$value")"
        [ -n "$value" ] || continue
        if validate_cidr "$value"; then
            printf '%s\n' "$value" >> "$ipv4_output"
        elif validate_domain "$value"; then
            printf '%s\n' "$value" >> "$domain_output"
        else
            fail "白名单格式无效: $value"
        fi
    done
}

build_allow_candidates() {
    local mode="$1" values="$2" ipv4_output="$3" domain_output="$4"
    : > "$ipv4_output" || fail "无法写入 IPv4 白名单"
    : > "$domain_output" || fail "无法写入域名白名单"
    if [ "$mode" = "apply" ]; then
        [ ! -s "$(allow_ipv4_file)" ] || cat "$(allow_ipv4_file)" >> "$ipv4_output"
        [ ! -s "$(allow_domain_file)" ] || cat "$(allow_domain_file)" >> "$domain_output"
    fi
    if [ -n "$values" ]; then
        append_allow_values "$values" "$ipv4_output" "$domain_output" || {
            rm -f "$ipv4_output" "$domain_output"
            exit 1
        }
    fi
    sort -u "$ipv4_output" -o "$ipv4_output"
    sort -u "$domain_output" -o "$domain_output"
    [ -s "$ipv4_output" ] || [ -s "$domain_output" ] || fail "白名单为空"
}

log_allow_state() {
    local cidr_count domain_count
    cidr_count=0
    domain_count=0
    [ ! -s "$(allow_ipv4_file)" ] || cidr_count="$(awk 'NF{c++} END{print c+0}' "$(allow_ipv4_file)")"
    [ ! -s "$(allow_domain_file)" ] || domain_count="$(awk 'NF{c++} END{print c+0}' "$(allow_domain_file)")"
    log_info "白名单: ${cidr_count} 个 IP/CIDR，${domain_count} 个域名"
}

providerdns_cache_field() {
    local domain="$1" field="$2" record
    record="$(run_providerdns --cache "$domain" 2>/dev/null)" || return 1
    awk -v f="$field" '{ print $f }' <<< "$record"
}

providerdns_cache_ip() {
    local ip
    ip="$(providerdns_cache_field "$1" 2 2>/dev/null || true)"
    validate_ipv4 "$ip" || return 1
    printf '%s\n' "$ip"
}

run_providerdns() {
    local bin
    bin="$(providerdns_bin)" || return 1
    PROVIDERDNS_ROOT="$ROOT" /bin/bash "$bin" "$@"
}

providerdns_local_source() {
    local script_dir local_path
    script_dir="$(cd "$(dirname "$(script_path)")" 2>/dev/null && pwd)"
    local_path="${script_dir}/${PROVIDERDNS_LOCAL_NAME}"
    [ -f "$local_path" ] || return 1
    printf '%s\n' "$local_path"
}

providerdns_bin() {
    local bin="${PROVIDERDNS_BIN:-/usr/local/sbin/providerdns.sh}" local_source
    [ -f "$bin" ] && { printf '%s\n' "$bin"; return 0; }
    if local_source="$(providerdns_local_source)"; then
        printf '%s\n' "$local_source"
        return 0
    fi
    return 1
}

find_providerdns() {
    providerdns_bin >/dev/null
}

require_providerdns() {
    find_providerdns && return 0
    fail "缺少 providerdns.sh"
}

providerdns_refresh() {
    require_providerdns
    PROVIDERDNS_LOCK_WAIT="${PROVIDERDNS_LOCK_WAIT:-10}" run_providerdns --refresh >/dev/null 2>&1
}

providerdns_set_sshg() {
    local domains_file="$1" script quoted_script hook_command
    require_providerdns
    script="$(script_path)"
    printf -v quoted_script '%q' "$script"
    hook_command="SSHG_QUIET=1 /bin/bash ${quoted_script} hook"
    run_providerdns --set "$PROVIDERDNS_CONSUMER" "$domains_file" "$hook_command" >/dev/null 2>&1
}

providerdns_unset_sshg() {
    find_providerdns || return 2
    run_providerdns --unset "$PROVIDERDNS_CONSUMER" >/dev/null 2>&1
}

set_providerdns_for_domains() {
    local domains_file="$1"
    if [ -s "$domains_file" ]; then
        providerdns_set_sshg "$domains_file"
    else
        providerdns_unset_sshg
    fi
}

refresh_providerdns_for_domains() {
    [ -s "$1" ] || { providerdns_unset_sshg; return 0; }
    set_providerdns_for_domains "$1"
    providerdns_refresh
}

build_sources_file() {
    local output="$1" ipv4_input="$2" domain_input="$3" value ip
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
            ip="$(providerdns_cache_ip "$value" || true)"
            if validate_ipv4 "$ip"; then
                ipv4_to_24_cidr "$ip" >> "$output"
            else
                log_warn "域名解析失败，已跳过: $value"
            fi
        done < "$domain_input"
    fi
    sort -u "$output" -o "$output"
    [ -s "$output" ] || fail "放行来源为空"
}

detect_ssh_ports() {
    local sshd ports port
    local -a port_arr
    if [ -n "${SSHG_PORTS:-}" ]; then
        IFS=',' read -ra port_arr <<< "$SSHG_PORTS"
        for port in "${port_arr[@]}"; do
            [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
        done
        printf '%s\n' "$SSHG_PORTS"
        return 0
    fi
    sshd="$(sshd_cmd)" || return 1
    ports="$("$sshd" -T 2>/dev/null | awk '$1=="port" && $2 ~ /^[0-9]+$/ && $2>=1 && $2<=65535 { print $2 }' | sort -un | tr '\n' ',' | sed 's/,$//')"
    [ -n "$ports" ] || return 1
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
    local config
    config="$(nft_main_file)"
    mkdir -p "$(dirname "$config")" || return 1
    touch "$config" || return 1
    grep -Eq '^[[:space:]]*include[[:space:]]+"?/etc/nftables\.d/\*\.nft"?[[:space:]]*$' "$config" && return 0
    printf '\ninclude "/etc/nftables.d/*.nft"\n' >> "$config" || return 1
}

ensure_nft_service() {
    local systemctl
    [ "$ROOT" != "/" ] && [ -z "${SSHG_SYSTEMCTL:-}" ] && return 0
    systemctl="$(systemctl_cmd 2>/dev/null || true)"
    [ -n "$systemctl" ] || return 0
    "$systemctl" enable nftables.service >/dev/null 2>&1 || log_warn "nftables.service 未启用，重启后规则可能失效"
}

nft_live_ready() {
    local nft="$1"
    "$nft" list table inet "$NFT_TABLE" >/dev/null 2>&1
}

rollback_file() {
    local target="$1" backup="$2" had_backup="$3"
    if [ "$had_backup" = "1" ]; then
        mv "$backup" "$target" 2>/dev/null || true
    else
        rm -f "$target" 2>/dev/null || true
    fi
}

rollback_dns_if_needed() {
    [ "$SSHG_DNS_ROLLBACK_ON_FAIL" = "1" ] || return 0
    SSHG_DNS_ROLLBACK_ON_FAIL=0
    reconcile_sshg_dns >/dev/null 2>&1 || true
}

fail_transaction() {
    rollback_dns_if_needed
    fail "$1"
}

apply_nft() {
    apply_nft_from_files "$(allow_ipv4_file)" "$(allow_domain_file)" "0"
}

rollback_allow_state() {
    rollback_file "$(allow_ipv4_file)" "$1" "$2"
    rollback_file "$(allow_domain_file)" "$3" "$4"
}

apply_nft_from_files() {
    local ipv4_input="$1" domain_input="$2" commit_allow="${3:-0}"
    local nft file tmp sources ports source_count ipv4_path domain_path ipv4_tmp domain_tmp ipv4_backup domain_backup nft_backup
    local had_ipv4=0 had_domain=0 had_nft=0
    nft="$(nft_cmd)" || fail_transaction "未检测到 nft"
    file="$(nft_file)"
    ipv4_path="$(allow_ipv4_file)"
    domain_path="$(allow_domain_file)"
    mkdir -p "$(dirname "$file")" || fail_transaction "无法创建 NFT 规则目录"
    tmp="${file}.tmp.$$"
    sources="${file}.sources.$$"
    build_sources_file "$sources" "$ipv4_input" "$domain_input"
    ports="$(detect_ssh_ports)" || fail_transaction "无法检测 SSH 端口"
    render_nft "$sources" "$tmp" "$ports"
    "$nft" -c -f "$tmp" >/dev/null 2>&1 || { rm -f "$tmp" "$sources"; fail_transaction "NFT 规则预检失败"; }
    ensure_nft_include || fail_transaction "无法写入 nftables include"
    ensure_nft_service
    source_count="$(wc -l < "$sources" | tr -d ' ')"
    if [ "$commit_allow" = "0" ] && cmp -s "$tmp" "$file" 2>/dev/null && nft_live_ready "$nft"; then
        rm -f "$tmp" "$sources"
        log_info "SSH 端口: ${ports}"
        log_info "放行来源: ${source_count} 个"
        log_info "NFT 规则未变化"
        return 0
    fi
    if [ "$commit_allow" = "1" ]; then
        mkdir -p "$(state_dir)" || fail_transaction "无法创建状态目录"
        ipv4_tmp="${ipv4_path}.tmp.$$"
        domain_tmp="${domain_path}.tmp.$$"
        ipv4_backup="${ipv4_path}.bak.$$"
        domain_backup="${domain_path}.bak.$$"
        [ ! -f "$ipv4_path" ] || { cp "$ipv4_path" "$ipv4_backup" || fail_transaction "无法备份 IPv4 白名单"; had_ipv4=1; }
        [ ! -f "$domain_path" ] || { cp "$domain_path" "$domain_backup" || { rollback_file "$ipv4_path" "$ipv4_backup" "$had_ipv4"; fail_transaction "无法备份域名白名单"; }; had_domain=1; }
        if [ -s "$ipv4_input" ]; then
            cp "$ipv4_input" "$ipv4_tmp" || { rollback_allow_state "$ipv4_backup" "$had_ipv4" "$domain_backup" "$had_domain"; fail_transaction "无法写入 IPv4 白名单"; }
            mv "$ipv4_tmp" "$ipv4_path" || { rm -f "$ipv4_tmp"; rollback_allow_state "$ipv4_backup" "$had_ipv4" "$domain_backup" "$had_domain"; fail_transaction "无法安装 IPv4 白名单"; }
            chmod 600 "$ipv4_path" 2>/dev/null || true
        else
            rm -f "$ipv4_path" || { rollback_allow_state "$ipv4_backup" "$had_ipv4" "$domain_backup" "$had_domain"; fail_transaction "无法清理 IPv4 白名单"; }
        fi
        if [ -s "$domain_input" ]; then
            cp "$domain_input" "$domain_tmp" || { rollback_allow_state "$ipv4_backup" "$had_ipv4" "$domain_backup" "$had_domain"; fail_transaction "无法写入域名白名单"; }
            mv "$domain_tmp" "$domain_path" || { rm -f "$domain_tmp"; rollback_allow_state "$ipv4_backup" "$had_ipv4" "$domain_backup" "$had_domain"; fail_transaction "无法安装域名白名单"; }
            chmod 600 "$domain_path" 2>/dev/null || true
        else
            rm -f "$domain_path" || { rollback_allow_state "$ipv4_backup" "$had_ipv4" "$domain_backup" "$had_domain"; fail_transaction "无法清理域名白名单"; }
        fi
    fi
    nft_backup="${file}.bak.$$"
    [ ! -f "$file" ] || { cp "$file" "$nft_backup" || { [ "$commit_allow" = "0" ] || rollback_allow_state "$ipv4_backup" "$had_ipv4" "$domain_backup" "$had_domain"; fail_transaction "无法备份 NFT 规则"; }; had_nft=1; }
    if ! mv "$tmp" "$file"; then
        [ "$commit_allow" = "0" ] || rollback_allow_state "$ipv4_backup" "$had_ipv4" "$domain_backup" "$had_domain"
        rm -f "$sources" "$nft_backup"
        fail_transaction "无法安装 NFT 规则"
    fi
    chmod 600 "$file" 2>/dev/null || true
    if ! "$nft" -f "$file" >/dev/null 2>&1; then
        rollback_file "$file" "$nft_backup" "$had_nft"
        [ "$commit_allow" = "0" ] || rollback_allow_state "$ipv4_backup" "$had_ipv4" "$domain_backup" "$had_domain"
        rm -f "$sources"
        fail_transaction "NFT 规则应用失败"
    fi
    rm -f "$sources" "$nft_backup" "$ipv4_backup" "$domain_backup"
    [ "$commit_allow" = "0" ] || log_allow_state
    log_info "SSH 端口: ${ports}"
    log_info "放行来源: ${source_count} 个"
    log_info "NFT 规则已应用"
}

script_path() {
    local resolved
    resolved="$(command -v readlink >/dev/null 2>&1 && readlink -f "$0" 2>/dev/null || true)"
    [ -n "$resolved" ] || resolved="$0"
    printf '%s\n' "$resolved"
}

reconcile_sshg_dns() {
    set_providerdns_for_domains "$(allow_domain_file)" >/dev/null 2>&1 || true
}

sync_rules_from_candidates() {
    local ipv4_candidate="$1" domain_candidate="$2"
    if [ -s "$domain_candidate" ]; then
        SSHG_DNS_ROLLBACK_ON_FAIL=1
        refresh_providerdns_for_domains "$domain_candidate" || fail_transaction "域名刷新失败"
    fi
    [ -s "$ipv4_candidate" ] || [ -s "$domain_candidate" ] || fail_transaction "白名单为空"
    apply_nft_from_files "$ipv4_candidate" "$domain_candidate" "1"
    SSHG_DNS_ROLLBACK_ON_FAIL=0
    set_providerdns_for_domains "$domain_candidate" || {
        local rc=$?
        [ "$rc" = "2" ] || return "$rc"
    }
    return 0
}

sync_rules() {
    local ipv4_candidate domain_candidate
    [ -s "$(allow_ipv4_file)" ] || [ -s "$(allow_domain_file)" ] || fail "白名单为空"
    ipv4_candidate="$(mktemp /tmp/sshg-allow-ipv4.XXXXXX)" || fail "无法创建 IPv4 白名单临时文件"
    domain_candidate="$(mktemp /tmp/sshg-allow-domain.XXXXXX)" || { rm -f "$ipv4_candidate"; fail "无法创建域名白名单临时文件"; }
    [ ! -s "$(allow_ipv4_file)" ] || cp "$(allow_ipv4_file)" "$ipv4_candidate" || { rm -f "$ipv4_candidate" "$domain_candidate"; fail "无法读取 IPv4 白名单"; }
    [ ! -s "$(allow_domain_file)" ] || cp "$(allow_domain_file)" "$domain_candidate" || { rm -f "$ipv4_candidate" "$domain_candidate"; fail "无法读取域名白名单"; }
    sync_rules_from_candidates "$ipv4_candidate" "$domain_candidate"
    rm -f "$ipv4_candidate" "$domain_candidate"
}

update_allow_state() {
    local mode="$1" values="$2" ipv4_candidate domain_candidate
    ipv4_candidate="$(mktemp /tmp/sshg-allow-ipv4.XXXXXX)" || fail "无法创建 IPv4 白名单临时文件"
    domain_candidate="$(mktemp /tmp/sshg-allow-domain.XXXXXX)" || { rm -f "$ipv4_candidate"; fail "无法创建域名白名单临时文件"; }
    build_allow_candidates "$mode" "$values" "$ipv4_candidate" "$domain_candidate"
    sync_rules_from_candidates "$ipv4_candidate" "$domain_candidate"
    rm -f "$ipv4_candidate" "$domain_candidate"
}

apply_cached_rules() {
    [ -s "$(allow_ipv4_file)" ] || [ -s "$(allow_domain_file)" ] || fail "白名单为空"
    apply_nft
}

clear_allow_state() {
    remove_active_nft
    rm -f "$(allow_ipv4_file)" "$(allow_domain_file)" "$(nft_file)"
    rmdir "$(state_dir)" 2>/dev/null || true
    providerdns_unset_sshg
    log_info "白名单已清空"
}

remove_active_nft() {
    local nft tmp existed=0
    nft="$(nft_cmd 2>/dev/null || true)"
    [ -n "$nft" ] || return 2
    "$nft" list table inet "$NFT_TABLE" >/dev/null 2>&1 && existed=1
    tmp="$(mktemp /tmp/sshg-clean.XXXXXX)" || return 3
    cat > "$tmp" << EOF
table inet ${NFT_TABLE}
delete table inet ${NFT_TABLE}
EOF
    "$nft" -f "$tmp" >/dev/null 2>&1 || true
    rm -f "$tmp"
    [ "$existed" = "1" ] || return 1
}

remove_file_report() {
    local file="$1" label="$2"
    if [ -e "$file" ]; then
        rm -f "$file" || fail "无法删除${label}: $file"
        log_info "已删除: ${label} | $file"
    else
        log_info "未发现: ${label} | $file"
    fi
}

remove_dir_report() {
    local dir="$1" label="$2"
    if [ -d "$dir" ]; then
        rm -rf "$dir" || fail "无法删除${label}: $dir"
        log_info "已删除: ${label} | $dir"
    else
        log_info "未发现: ${label} | $dir"
    fi
}

remove_all() {
    local rc
    remove_active_nft
    rc=$?
    case "$rc" in
        0) log_info "已删除 live NFT table: ${NFT_TABLE}" ;;
        1) log_info "未发现 live NFT table: ${NFT_TABLE}" ;;
        2) log_warn "未检测到 nft，跳过 live NFT table 清理" ;;
        *) log_warn "无法创建临时文件，跳过 live NFT table 清理" ;;
    esac
    remove_file_report "$(sshd_dropin)" "SSH 配置"
    remove_file_report "$(key_file)" "托管 root 公钥"
    remove_file_report "$(nft_file)" "NFT 持久规则"
    remove_dir_report "$(state_dir)" "sshg 业务状态目录"
    if providerdns_unset_sshg; then
        log_info "已取消 Provider DNS 注册: ${PROVIDERDNS_CONSUMER}"
    else
        rc=$?
        [ "$rc" = "2" ] && log_info "未检测到 Provider DNS，跳过 DNS 注册清理" || fail "无法取消 Provider DNS 注册"
    fi
    reload_ssh
    log_info "保留共享配置: $(nft_main_file) include 与 Provider DNS runtime"
    log_info "SSH 防护已移除"
}

show_help() {
    cat << 'EOF'
Usage:
  sshg.sh --apply config=ssh allow=1.2.3.4,1.2.3.0/24,example.com key='ssh-ed25519 AAAA...'
  sshg.sh --reset config=ssh allow=1.2.3.4,example.com key='ssh-ed25519 AAAA...'
  sshg.sh --sync
  sshg.sh --remove

Actions:
  --apply        apply provided config/key/allow changes
  --reset        set target config/key/allow state, missing fields are removed
  --sync         resolve domains and refresh nft
  --remove       remove sshg files and nft table

Parameters:
  config=ssh     write ssh hardening config
  key=...        write root authorized_keys3
  allow=...      comma-separated IPv4, IPv4 CIDR, or domain entries
EOF
}

main() {
    local action="${1:-}" mode="" allow_values="" key_value="" config_value="" arg
    local allow_seen=0 key_seen=0 config_seen=0 did_change=0 ssh_reload_needed=0
    case "$action" in
        --apply|apply)
            shift
            mode="state"
            ;;
        --reset|reset) mode="state"; shift ;;
        --sync|sync) shift ;;
        --remove|remove) shift ;;
        hook) shift ;;
        help|-h|--help|"") show_help; [ -n "$action" ]; exit $? ;;
        *) fail "未知操作" ;;
    esac

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

    require_root
    case "$action" in
        --apply|apply|--reset|reset|--sync|sync|--remove|remove|hook) acquire_lock ;;
    esac
    case "$action" in
        --apply|apply)
            [ "$config_seen" = "0" ] || [ "$config_value" = "ssh" ] || fail "配置参数无效"
            [ "$key_seen" = "0" ] || public_key_valid "$(trim "$key_value")" || fail "SSH 公钥格式无效"
            if [ "$config_seen" = "1" ] && [ "$key_seen" = "0" ]; then
                root_key_exists || fail "未检测到 root SSH 公钥"
            fi
            if [ "$allow_seen" = "1" ]; then
                update_allow_state "apply" "$allow_values"
                did_change=1
            fi
            if [ "$key_seen" = "1" ]; then
                write_key "$key_value"
                did_change=1
            fi
            if [ "$config_seen" = "1" ]; then
                root_key_exists || fail "未检测到 root SSH 公钥"
                write_ssh_config
                ssh_reload_needed=1
                did_change=1
            fi
            [ "$did_change" = "1" ] || fail "没有需要执行的操作"
            [ "$ssh_reload_needed" = "0" ] || reload_ssh
            ;;
        --reset|reset)
            [ "$config_seen" = "0" ] || [ "$config_value" = "ssh" ] || fail "配置参数无效"
            [ "$key_seen" = "0" ] || public_key_valid "$(trim "$key_value")" || fail "SSH 公钥格式无效"
            if [ "$config_seen" = "1" ] && [ "$key_seen" = "0" ]; then
                root_key_exists_without_managed || fail "未检测到 root SSH 公钥"
            fi
            if [ "$allow_seen" = "1" ]; then
                update_allow_state "reset" "$allow_values"
            else
                clear_allow_state
            fi
            if [ "$key_seen" = "1" ]; then
                write_key "$key_value"
            else
                remove_key
            fi
            if [ "$config_seen" = "1" ]; then
                root_key_exists || fail "未检测到 root SSH 公钥"
                write_ssh_config
            else
                remove_ssh_config
            fi
            reload_ssh
            ;;
        --sync|sync)
            [ -s "$(allow_ipv4_file)" ] || [ -s "$(allow_domain_file)" ] || fail "白名单为空"
            sync_rules
            ;;
        hook)
            SSHG_QUIET=1
            apply_cached_rules
            ;;
        --remove|remove)
            remove_all
            ;;
    esac
}

main "$@"
