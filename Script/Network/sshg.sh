#!/bin/bash

set -o pipefail

ROOT="${SSHG_ROOT:-/}"
ROOT_PREFIX="${ROOT%/}"
NFT_TABLE="sshg"
PROVIDERDNS_BIN="${PROVIDERDNS_BIN:-}"
PROVIDERDNS_CONSUMER="sshg"
SERVICE_ALLOW_MARK="0x40000000"
SERVICE_ALLOW_MASK="$(printf '0x%08x' "$(( 0xffffffff & ~SERVICE_ALLOW_MARK ))")"
SSHD_DROPIN="${ROOT_PREFIX}/etc/ssh/sshd_config.d/00-sshg.conf"
KEY_FILE="${ROOT_PREFIX}/root/.ssh/authorized_keys3"
STATE_DIR="${ROOT_PREFIX}/etc/sshg"
ALLOW_FILE="${STATE_DIR}/allow.db"
NFT_FILE="${ROOT_PREFIX}/etc/nftables.d/sshg.nft"
NFT_MAIN_FILE="${ROOT_PREFIX}/etc/nftables.conf"
NFT_INCLUDE_MARKER="# Managed by Provider sshg.sh"
SSH_CONFIG_CHANGED=0
SSHG_NFT_TOUCHED=0
TX_DIR=""
TX_PORTS=""
TX_SOURCE_COUNT=0

DOMAIN_LABEL_RE='[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?'

AWK_IPV4='
function ip2int(ip, parts, i, value) {
    if (split(ip, parts, ".") != 4) return -1
    value = 0
    for (i = 1; i <= 4; i++) {
        if (parts[i] !~ /^[0-9]+$/ || parts[i] + 0 > 255) return -1
        value = value * 256 + parts[i]
    }
    return value
}
'

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
    log_error "$*"
    exit 1
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
  key=...        写入 root 使用的 SSH 公钥
  allow=...      逗号分隔的 IPv4、IPv4 CIDR 或域名

环境：
  SSHG_ALLOW_LOCKOUT=1   跳过失联准入检查

兼容入口：apply、reset、sync、remove；hook 仅供 ProviderDNS 回调使用。
EOF
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    printf '%s' "${value%"${value##*[![:space:]]}"}"
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

# 纯数字点分或带前缀长度的值一律按 IPv4 判定，避免非法 IP 落到域名分支。
allow_kind() {
    local value="$1"
    if [[ "$value" =~ ^[0-9.]+(/[0-9]+)?$ ]] || [[ "$value" == */* ]]; then
        validate_cidr "$value" && printf 'ipv4\n'
        return
    fi
    validate_domain "$value" && printf 'domain\n'
}

validate_domain() {
    local domain="$1" pattern="^${DOMAIN_LABEL_RE}([.]${DOMAIN_LABEL_RE})*$"
    [ -n "$domain" ] && [ "${#domain}" -le 253 ] && [[ "$domain" =~ $pattern ]]
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
    case "$key_type" in
        ssh-ed25519|ssh-rsa) ;;
        *)
            return 1
            ;;
    esac
    [[ "$key_body" =~ ^[A-Za-z0-9+/=]+$ ]] || return 1
    printf '%s %s\n' "$key_type" "$key_body"
}

require_root() {
    [ "$ROOT" != "/" ] && return 0
    [ "$(id -u)" = "0" ] || fail "此操作必须以 root 权限运行"
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

missing_dependencies() {
    nft_cmd >/dev/null 2>&1 || printf 'nftables\n'
    sshd_cmd >/dev/null 2>&1 || printf 'openssh-server\n'
    command -v flock >/dev/null 2>&1 || printf 'util-linux\n'
}

ensure_sshg_dependencies() {
    local -a missing=()
    command -v apt-get >/dev/null 2>&1 || fail "仅支持使用 apt-get 的 Debian 类系统"
    mapfile -t missing < <(missing_dependencies)
    [ "${#missing[@]}" -eq 0 ] && return 0
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || fail "apt-get update 失败"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1 ||
        fail "依赖安装失败：${missing[*]}"
    log_info "已安装依赖：${missing[*]}"
    mapfile -t missing < <(missing_dependencies)
    [ "${#missing[@]}" -eq 0 ] || fail "安装依赖后仍未检测到：${missing[*]}"
}

acquire_lock() {
    local wait="${SSHG_LOCK_WAIT:-5}"
    mkdir -p "${ROOT_PREFIX}/run/sshg" || fail "无法创建锁目录"
    exec 9>"${ROOT_PREFIX}/run/sshg/lock" || fail "无法创建锁文件"
    command -v flock >/dev/null 2>&1 || fail "缺少依赖命令：flock"
    [[ "$wait" =~ ^[0-9]+$ ]] || wait=0
    if [ "$wait" -gt 0 ]; then
        flock -w "$wait" 9
    else
        flock -n 9
    fi || fail "检测到其他任务正在执行中，请稍后重试"
}

# 候选阶段的全部中间态都落在 TX_DIR，由 trap 保证任何退出路径都不残留。
tx_open() {
    mkdir -p "$STATE_DIR" || fail "无法创建状态目录"
    TX_DIR="$(mktemp -d "${STATE_DIR}/.tx.XXXXXX")" || fail "无法创建候选目录"
}

tx_cleanup() {
    [ -n "$TX_DIR" ] || return 0
    rm -rf "$TX_DIR"
    rmdir "$STATE_DIR" 2>/dev/null || true
}

trap tx_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

guard_legacy_layout() {
    local path
    for path in "${STATE_DIR}/allow.ipv4" "${STATE_DIR}/allow.domain"; do
        [ -e "$path" ] || continue
        fail "检测到旧版本状态文件：${path}；请先执行 sshg.sh --remove 卸载后再运行本版本"
    done
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

root_key_exists() {
    local key="${1:-}" include_managed="${2:-1}" file
    local -a files=("${ROOT_PREFIX}/root/.ssh/authorized_keys" "${ROOT_PREFIX}/root/.ssh/authorized_keys2")
    [ "$include_managed" = "0" ] || files+=("$KEY_FILE")
    for file in "${files[@]}"; do
        key_file_has_key "$file" "$key" && return 0
    done
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
    mkdir -p "${file%/*}" || fail "无法创建密钥目录"
    tmp="$(mktemp "${file}.XXXXXX")" || fail "无法创建托管密钥临时文件"
    chmod 700 "${file%/*}" 2>/dev/null || true
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

sshd_has_dropin_include() {
    [ "$ROOT" != "/" ] && return 0
    [ -f "${ROOT_PREFIX}/etc/ssh/sshd_config" ] || return 1
    grep -Eiq '^[[:space:]]*Include[[:space:]]+"?/etc/ssh/sshd_config\.d/\*\.conf"?([[:space:]]|$)' \
        "${ROOT_PREFIX}/etc/ssh/sshd_config"
}

sshd_effective_config_ok() {
    local effective
    effective="$("$1" -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null)" || return 1
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
    mkdir -p "${file%/*}" || fail "无法创建 SSH 配置目录"
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
    # sshd -T 只读真实路径，候选必须先落盘才能校验；失败时保留候选并停在此处。
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
        if ! "$systemctl" reload "$unit" >/dev/null 2>&1 ||
           ! "$systemctl" is-active --quiet "$unit" >/dev/null 2>&1; then
            fail "SSH 重载失败：$unit"
        fi
        log_info "SSH 已重载：$unit"
        return 0
    done
    fail "SSH 服务未运行，请执行：systemctl status ssh.service sshd.service"
}

run_providerdns() {
    local bin="$PROVIDERDNS_BIN"
    if [ -z "$bin" ]; then
        bin="$(dirname "$(realpath "$0")")/providerdns.sh"
    fi
    [ -f "$bin" ] || return 127
    PROVIDERDNS_ROOT="$ROOT" /bin/bash "$bin" "$@"
}

# ProviderDNS 缺失（rc=127）视为可接受：sshg 允许在没有域名订阅能力的机器上运行。
providerdns_ok() {
    local rc="$1"
    [ "$rc" = "0" ] || [ "$rc" = "127" ]
}

providerdns_set_sshg() {
    local domains_file="$1" script quoted_script hook_command
    script="$(realpath "$0")"
    printf -v quoted_script '%q' "$script"
    hook_command="SSHG_QUIET=1 /bin/bash ${quoted_script} hook"
    run_providerdns --set "$PROVIDERDNS_CONSUMER" "$domains_file" "$hook_command" >/dev/null
}

providerdns_unset_sshg() {
    run_providerdns --unset "$PROVIDERDNS_CONSUMER" >/dev/null
}

# 声明真值：每行 "<类型>\t<值>"，类型为 ipv4 或 domain。
allow_declarations_from() {
    awk -F'\t' '($1=="ipv4" || $1=="domain") && $2!="" { print }' "$1"
}

allow_values_of() {
    local kind="$1" file="$2"
    [ -s "$file" ] || return 0
    awk -F'\t' -v kind="$kind" '$1==kind && $2!="" { print $2 }' "$file"
}

tx_build_allow() {
    local mode="$1" values="$2" output="${TX_DIR}/allow.db" value kind
    : > "$output" || fail "无法写入白名单候选"
    if [ "$mode" != "reset" ] && [ -s "$ALLOW_FILE" ]; then
        allow_declarations_from "$ALLOW_FILE" >> "$output" || fail "无法读取白名单声明"
    fi
    if [ "$mode" != "sync" ] && [ -n "$values" ]; then
        while IFS= read -r value || [ -n "$value" ]; do
            value="$(trim "$value")"
            [ -n "$value" ] || continue
            kind="$(allow_kind "$value")"
            [ -n "$kind" ] || fail "白名单格式无效: $value"
            printf '%s\t%s\n' "$kind" "$value" >> "$output"
        done < <(printf '%s' "$values" | tr ',' '\n')
    fi
    sort -u "$output" -o "$output" || fail "无法整理白名单候选"
    [ -s "$output" ] || fail "白名单为空"
}

# 候选解析可刷新共享 DNS 缓存，但不修改订阅或执行 hook。
tx_resolve() {
    local mode="$1" domains="${TX_DIR}/domains" snapshot="${TX_DIR}/snapshot"
    local sources="${TX_DIR}/sources" rc
    allow_values_of domain "${TX_DIR}/allow.db" > "$domains" || fail "无法提取候选域名"
    : > "$snapshot" || fail "无法写入解析快照"
    if [ -s "$domains" ]; then
        PROVIDERDNS_LOCK_WAIT="${PROVIDERDNS_LOCK_WAIT:-10}" \
            run_providerdns --snapshot "$mode" "$domains" > "$snapshot"
        rc=$?
        [ "$rc" = "0" ] || fail "域名解析失败"
    fi
    allow_values_of ipv4 "${TX_DIR}/allow.db" > "$sources" || fail "无法提取放行来源"
    awk -F'\t' "$AWK_IPV4"'
        NF >= 2 && ip2int($2) >= 0 { sub(/[0-9]+$/, "0/24", $2); print $2; next }
        NF { printf "[WARNING] 域名解析失败，已跳过：%s\n", $1 > "/dev/stderr" }
    ' "$snapshot" >> "$sources" || fail "无法展开域名放行来源"
    sort -u "$sources" -o "$sources" || fail "无法整理放行来源"
    [ -s "$sources" ] || fail "放行来源为空"
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

tx_render() {
    local sources="${TX_DIR}/sources" output="${TX_DIR}/sshg.nft" nft ports elements
    nft="$(nft_cmd)" || fail "未检测到 nft"
    ports="$(detect_ssh_ports)" || fail "无法检测 SSH 端口"
    elements="$(awk '{ printf "%s%s", separator, $0; separator=",\n            " } END { print "" }' "$sources")" ||
        fail "无法生成放行来源集合"
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
            ${elements}
        }
    }

    chain input {
        type filter hook input priority -20; policy accept;
        ct state established,related accept
        iifname "lo" accept
        meta nfproto ipv4 tcp dport { ${ports} } ip saddr @allowed_ipv4 meta mark set meta mark | ${SERVICE_ALLOW_MARK} accept
        meta nfproto ipv4 tcp dport { ${ports} } drop
        meta nfproto ipv6 tcp dport { ${ports} } drop
    }

    chain input_cleanup {
        type filter hook input priority 10; policy accept;
        tcp dport { ${ports} } meta mark & ${SERVICE_ALLOW_MARK} != 0 meta mark set meta mark & ${SERVICE_ALLOW_MASK}
    }
}
EOF
    "$nft" -c -f "$output" >/dev/null 2>&1 || fail "NFT 规则预检失败"
    TX_PORTS="$ports"
    TX_SOURCE_COUNT="$(wc -l < "$sources" | tr -d ' ')"
}

# 准入门：提交前对"变更后的状态"提问，任一条不成立即停在零提交处。
session_peer_ip() {
    local peer=""
    if [ -n "${SSH_CONNECTION:-}" ]; then
        read -r peer _ <<< "$SSH_CONNECTION"
    elif [ -n "${SSH_CLIENT:-}" ]; then
        read -r peer _ <<< "$SSH_CLIENT"
    fi
    [ -n "$peer" ] || return 1
    printf '%s\n' "$peer"
}

admission_network() {
    local sources="${TX_DIR}/sources" peer
    [ "${SSHG_ALLOW_LOCKOUT:-0}" != "1" ] || return 0
    peer="$(session_peer_ip)" || return 0
    validate_ipv4 "$peer" ||
        fail "当前 SSH 来源 ${peer} 无法被 IPv4 白名单覆盖；如确认请设置 SSHG_ALLOW_LOCKOUT=1 重试"
    awk -v peer="$peer" "$AWK_IPV4"'
        BEGIN { target = ip2int(peer); if (target < 0) exit 0 }
        {
            network = $0; length_bits = 32
            if (index($0, "/")) {
                network = substr($0, 1, index($0, "/") - 1)
                length_bits = substr($0, index($0, "/") + 1) + 0
            }
            base = ip2int(network)
            if (base < 0) next
            block = 2 ^ (32 - length_bits)
            if (int(target / block) == int(base / block)) { found = 1; exit }
        }
        END { exit(found ? 0 : 1) }
    ' "$sources" && return 0
    log_error "当前 SSH 会话来源 ${peer} 不在候选放行来源中，应用后将失去访问"
    log_error "放行来源：$(tr '\n' ' ' < "$sources")"
    fail "如确认要从其他网络接入，请设置 SSHG_ALLOW_LOCKOUT=1 重试"
}

admission_auth() {
    local managed_after="$1" key="${2:-}"
    [ "${SSHG_ALLOW_LOCKOUT:-0}" != "1" ] || return 0
    if [ "$managed_after" = "set" ]; then
        root_key_exists "" 0 || key_file_has_key "$KEY_FILE" "$key" ||
            log_warning "提交后 root 仅保留本次提供的公钥，请确认该公钥可用"
        return 0
    fi
    [ "$managed_after" = "remove" ] || return 0
    root_key_exists "" 0 && return 0
    fail "移除托管公钥后 root 将没有可用公钥；如确认请设置 SSHG_ALLOW_LOCKOUT=1 重试"
}

ensure_nft_include() {
    local tmp
    if grep -Eq '^[[:space:]]*include[[:space:]]+"?/etc/nftables\.d/(\*|sshg)\.nft"?[[:space:]]*$' \
        "$NFT_MAIN_FILE" 2>/dev/null; then
        return 0
    fi
    mkdir -p "${NFT_MAIN_FILE%/*}" || return 1
    tmp="$(mktemp "${NFT_MAIN_FILE}.XXXXXX")" || return 1
    if [ -e "$NFT_MAIN_FILE" ]; then
        if ! cp -p "$NFT_MAIN_FILE" "$tmp"; then
            rm -f "$tmp"
            return 1
        fi
    else
        chmod 644 "$tmp" 2>/dev/null || true
    fi
    if ! printf '\n%s\ninclude "/etc/nftables.d/sshg.nft"\n' "$NFT_INCLUDE_MARKER" >> "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv "$tmp" "$NFT_MAIN_FILE"; then
        rm -f "$tmp"
        return 1
    fi
    log_info "已写入 nftables include：$NFT_MAIN_FILE"
}

remove_nft_include() {
    local tmp
    [ -f "$NFT_MAIN_FILE" ] || return 0
    grep -Fqx "$NFT_INCLUDE_MARKER" "$NFT_MAIN_FILE" || return 0
    tmp="$(mktemp "${NFT_MAIN_FILE}.XXXXXX")" || fail "无法创建 nftables 主配置候选"
    if ! awk -v marker="$NFT_INCLUDE_MARKER" '
        $0 == marker { owned = 1; next }
        owned && $0 ~ /^[[:space:]]*include[[:space:]]+"?\/etc\/nftables[.]d\/sshg[.]nft"?[[:space:]]*$/ {
            owned = 0
            next
        }
        { owned = 0; print }
    ' "$NFT_MAIN_FILE" > "$tmp" || ! mv "$tmp" "$NFT_MAIN_FILE"; then
        rm -f "$tmp"
        fail "无法清理 nftables include"
    fi
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

publish_file() {
    local source="$1" target="$2" tmp
    tmp="$(mktemp "${target}.XXXXXX")" || return 1
    if ! cp "$source" "$tmp" || ! chmod 600 "$tmp" || ! mv "$tmp" "$target"; then
        rm -f "$tmp"
        return 1
    fi
}

# 提交阶段：防火墙排在最后，任何更早的失败都保留旧的已知可用白名单。
commit_firewall() {
    local commit_allow="$1" nft allow_unchanged=1
    local candidate="${TX_DIR}/sshg.nft"
    nft="$(nft_cmd)" || fail "未检测到 nft"
    mkdir -p "${NFT_FILE%/*}" || fail "无法创建 NFT 规则目录"
    ensure_nft_include || fail "无法写入 nftables include"
    ensure_nft_service
    [ "$commit_allow" = "0" ] || cmp -s "${TX_DIR}/allow.db" "$ALLOW_FILE" 2>/dev/null ||
        allow_unchanged=0
    if [ "$allow_unchanged" = "1" ] && cmp -s "$candidate" "$NFT_FILE" 2>/dev/null &&
        "$nft" list table inet "$NFT_TABLE" >/dev/null 2>&1; then
        log_info "SSH 防火墙规则未变化，无需重新应用"
        return 0
    fi
    if [ "$commit_allow" = "1" ]; then
        mkdir -p "$STATE_DIR" || fail "无法创建状态目录"
        publish_file "${TX_DIR}/allow.db" "$ALLOW_FILE" || fail "白名单声明提交失败"
    fi
    publish_file "$candidate" "$NFT_FILE" ||
        fail "白名单声明已提交但持久规则未安装；修复后请执行 sshg.sh --sync"
    "$nft" -f "$NFT_FILE" >/dev/null 2>&1 ||
        fail "持久规则已安装但 live 规则未应用；修复后请执行 sshg.sh --sync"
    log_info "SSH 防火墙规则已应用：端口 ${TX_PORTS}，放行来源 ${TX_SOURCE_COUNT} 个"
}

commit_dns() {
    local rc
    if [ -s "${TX_DIR}/domains" ]; then
        providerdns_set_sshg "${TX_DIR}/domains"
    else
        providerdns_unset_sshg
    fi
    rc=$?
    providerdns_ok "$rc" || fail "无法对齐 Provider DNS 注册"
}

remove_active_nft() {
    local nft tmp
    nft="$(nft_cmd 2>/dev/null || true)"
    [ -n "$nft" ] || fail "未检测到 nft，无法验证 live NFT table 已清理"
    if ! "$nft" list table inet "$NFT_TABLE" >/dev/null 2>&1; then
        "$nft" list tables >/dev/null 2>&1 || fail "无法读取 nftables 状态"
        return 0
    fi
    tmp="$(mktemp "${ROOT_PREFIX}/run/sshg/clean.XXXXXX")" || fail "无法创建 NFT 清理临时文件"
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
    log_info "已删除 live NFT table：${NFT_TABLE}"
}

clear_firewall() {
    local changed=0 rc
    [ ! -e "$ALLOW_FILE" ] || changed=1
    [ ! -e "$NFT_FILE" ] || changed=1
    remove_active_nft
    rm -f "$ALLOW_FILE" "$NFT_FILE" || fail "无法清理 SSH 白名单"
    rmdir "$STATE_DIR" 2>/dev/null || true
    providerdns_unset_sshg
    rc=$?
    providerdns_ok "$rc" || fail "无法取消 Provider DNS 注册"
    [ "$changed" = "0" ] || log_info "SSH 白名单已清空"
}

remove_path_report() {
    local target="$1" label="$2"
    [ -e "$target" ] || [ -L "$target" ] || return 0
    rm -rf "$target" || fail "无法删除${label}：$target"
    log_info "已删除${label}：$target"
}

sshg_resources_exist() {
    [[ -e "$SSHD_DROPIN" || -L "$SSHD_DROPIN" || -e "$KEY_FILE" || -L "$KEY_FILE" ||
        -e "$NFT_FILE" || -L "$NFT_FILE" || -d "$STATE_DIR" ]] ||
        grep -Fqx "$NFT_INCLUDE_MARKER" "$NFT_MAIN_FILE" 2>/dev/null
}

remove_all() {
    local rc ssh_changed=0
    remove_active_nft
    if ! sshg_resources_exist && [ "$SSHG_NFT_TOUCHED" = "0" ]; then
        providerdns_unset_sshg
        rc=$?
        providerdns_ok "$rc" || fail "无法取消 Provider DNS 注册"
        log_info "SSH 防护已不存在，无需移除"
        return 0
    fi
    if [ -e "$SSHD_DROPIN" ] || [ -L "$SSHD_DROPIN" ]; then
        ssh_changed=1
    fi
    remove_path_report "$SSHD_DROPIN" "SSH 配置"
    remove_path_report "$KEY_FILE" "托管 root 公钥"
    remove_path_report "$NFT_FILE" "NFT 持久规则"
    remove_path_report "$STATE_DIR" "sshg 业务状态目录"
    remove_nft_include
    providerdns_unset_sshg
    rc=$?
    if [ "$rc" = "0" ]; then
        log_info "已取消 Provider DNS 注册：${PROVIDERDNS_CONSUMER}"
    else
        providerdns_ok "$rc" || fail "无法取消 Provider DNS 注册"
    fi
    [ "$ssh_changed" = "0" ] || reload_ssh
    log_info "SSH 防护已移除"
}

run_change() {
    local mode="$1" allow_values="$2" key_value="$3"
    local allow_seen="$4" key_seen="$5" config_seen="$6"
    local want_allow=0 want_clear=0 managed_after=keep

    if [ "$mode" = "sync" ] || [ "$allow_seen" = "1" ]; then
        want_allow=1
    elif [ "$mode" = "reset" ]; then
        want_clear=1
    fi
    if [ "$key_seen" = "1" ]; then
        managed_after=set
    elif [ "$mode" = "reset" ]; then
        managed_after=remove
    fi

    # 候选阶段：允许刷新 DNS 缓存，不提交业务配置。
    if [ "$want_allow" = "1" ]; then
        tx_open
        tx_build_allow "$mode" "$allow_values"
        tx_resolve refresh
        tx_render
    fi

    # 准入门
    [ "$want_allow" = "0" ] || admission_network
    admission_auth "$managed_after" "$key_value"

    # 提交阶段：密钥 → SSH 配置 → 防火墙 → DNS 订阅
    if [ "$managed_after" = "set" ]; then
        write_key "$key_value"
    elif [ "$managed_after" = "remove" ]; then
        remove_key
    fi
    if [ "$config_seen" = "1" ]; then
        root_key_exists || fail "未检测到 root SSH 公钥"
        write_ssh_config
    elif [ "$mode" = "reset" ]; then
        remove_ssh_config
    fi
    [ "$SSH_CONFIG_CHANGED" = "0" ] || reload_ssh
    if [ "$want_allow" = "1" ]; then
        commit_firewall 1
        commit_dns
    elif [ "$want_clear" = "1" ]; then
        clear_firewall
    fi
}

run_hook() {
    SSHG_QUIET=1
    [ -s "$ALLOW_FILE" ] || fail "白名单为空"
    tx_open
    allow_declarations_from "$ALLOW_FILE" > "${TX_DIR}/allow.db" || fail "无法读取白名单声明"
    tx_resolve cache
    tx_render
    commit_firewall 0
}

main() {
    local action="" raw_action="${1:-}" allow_values="" key_value="" arg
    local allow_seen=0 key_seen=0 config_seen=0
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
                [ "${arg#config=}" = "ssh" ] || fail "配置参数无效"
                ;;
            *)
                fail "未知参数: $arg"
                ;;
        esac
        shift
    done

    if [ "$action" = "apply" ] || [ "$action" = "reset" ]; then
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
    [ "$action" = remove ] || guard_legacy_layout
    case "$action" in
        apply|reset|sync)
            run_change "$action" "$allow_values" "$key_value" \
                "$allow_seen" "$key_seen" "$config_seen"
            ;;
        hook)
            run_hook
            ;;
        remove)
            remove_all
            ;;
    esac
}

main "$@"
