#!/bin/bash

set -o pipefail

SSHD_DROPIN="/etc/ssh/sshd_config.d/00-sshg.conf"
KEY_FILE="/root/.ssh/authorized_keys3"
SSH_CONFIG_CHANGED=0

log_info() {
    printf '[INFO] %s\n' "$*"
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
用法:
  sshg.sh --apply [config=ssh] [key='ssh-ed25519 AAAA...']
  sshg.sh --reset [config=ssh] [key='ssh-ed25519 AAAA...']
  sshg.sh --remove
  sshg.sh -h, --help
EOF
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    printf '%s' "${value%"${value##*[![:space:]]}"}"
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
    [ "$(id -u)" = "0" ] || fail "此操作必须以 root 权限运行"
}

sshd_cmd() {
    command -v sshd 2>/dev/null && return 0
    [ -x /usr/sbin/sshd ] || return 1
    printf '%s\n' /usr/sbin/sshd
}

acquire_lock() {
    command -v flock >/dev/null 2>&1 || fail "缺少依赖命令：flock"
    mkdir -p /run/sshg || fail "无法创建锁目录"
    exec 9>/run/sshg/lock || fail "无法创建锁文件"
    flock -w 5 9 || fail "检测到其他任务正在执行中，请稍后重试"
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
    local -a files=(/root/.ssh/authorized_keys /root/.ssh/authorized_keys2)
    [ "$include_managed" = "0" ] || files+=("$KEY_FILE")
    for file in "${files[@]}"; do
        key_file_has_key "$file" "$key" && return 0
    done
    return 1
}

write_key() {
    local key="$1" tmp
    if root_key_exists "$key" 0; then
        remove_key
        return 0
    fi
    key_file_has_key "$KEY_FILE" "$key" && return 0
    mkdir -p "${KEY_FILE%/*}" || fail "无法创建密钥目录"
    chmod 700 "${KEY_FILE%/*}" 2>/dev/null || true
    tmp="$(mktemp "${KEY_FILE}.XXXXXX")" || fail "无法创建托管密钥临时文件"
    printf '%s\n' "$key" > "$tmp" || fail "无法写入托管密钥"
    chmod 600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$KEY_FILE" || fail "无法安装托管密钥"
    log_info "已写入托管密钥"
}

remove_key() {
    [ -e "$KEY_FILE" ] || [ -L "$KEY_FILE" ] || return 0
    rm -f "$KEY_FILE" || fail "无法删除托管密钥"
    log_info "已删除托管密钥"
}

sshd_has_dropin_include() {
    [ -f /etc/ssh/sshd_config ] || return 1
    grep -Eiq '^[[:space:]]*Include[[:space:]]+"?/etc/ssh/sshd_config\.d/\*\.conf"?([[:space:]]|$)' \
        /etc/ssh/sshd_config
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
    mkdir -p /run/sshd 2>/dev/null || true
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
    local unit
    command -v systemctl >/dev/null 2>&1 || fail "未检测到 systemctl，无法重载 SSH"
    for unit in ssh.service sshd.service; do
        systemctl is-active --quiet "$unit" >/dev/null 2>&1 || continue
        if ! systemctl reload "$unit" >/dev/null 2>&1 ||
           ! systemctl is-active --quiet "$unit" >/dev/null 2>&1; then
            fail "SSH 重载失败：$unit"
        fi
        log_info "SSH 已重载：$unit"
        return 0
    done
    fail "SSH 服务未运行，请执行：systemctl status ssh.service sshd.service"
}

admission_auth() {
    local managed_after="$1" key="$2" config_seen="$3"
    root_key_exists "" 0 && return 0
    case "$managed_after" in
        set)
            key_file_has_key "$KEY_FILE" "$key" ||
                log_warning "提交后 root 仅保留本次提供的公钥，请确认该公钥可用"
            ;;
        keep)
            [ "$config_seen" = "0" ] || key_file_has_key "$KEY_FILE" || fail "未检测到 root SSH 公钥"
            ;;
        remove)
            [ "$config_seen" = "0" ] || fail "未检测到 root SSH 公钥"
            key_file_has_key "$KEY_FILE" || return 0
            [ "${SSHG_ALLOW_LOCKOUT:-0}" = "1" ] ||
                fail "移除托管公钥后 root 将没有可用公钥；如确认请设置 SSHG_ALLOW_LOCKOUT=1 重试"
            ;;
    esac
}

run_change() {
    local mode="$1" key="$2" key_seen="$3" config_seen="$4" managed_after=keep

    if [ "$key_seen" = "1" ]; then
        managed_after=set
    elif [ "$mode" = "reset" ]; then
        managed_after=remove
    fi

    admission_auth "$managed_after" "$key" "$config_seen"

    if [ "$managed_after" = "set" ]; then
        write_key "$key"
    elif [ "$managed_after" = "remove" ]; then
        remove_key
    fi
    if [ "$config_seen" = "1" ]; then
        write_ssh_config
    elif [ "$mode" = "reset" ]; then
        remove_ssh_config
    fi
    [ "$SSH_CONFIG_CHANGED" = "0" ] || reload_ssh
}

main() {
    local action="" key_value="" arg key_seen=0 config_seen=0
    case "${1:-}" in
        --apply|--reset|--remove)
            action="${1#--}"
            shift
            ;;
        -h|--help)
            show_help
            return 0
            ;;
        "")
            show_help
            return 1
            ;;
        *)
            fail "未知操作：$1"
            ;;
    esac

    if [ "$action" = "remove" ]; then
        [ "$#" -eq 0 ] || fail "动作 --remove 不接受参数"
        action=reset
    fi

    while [ "$#" -gt 0 ]; do
        arg="$1"
        case "$arg" in
            key=*)
                key_seen=1
                key_value="$(trim "${arg#key=}")"
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

    if [ "$key_seen" = "1" ]; then
        public_key_id "$key_value" >/dev/null || fail "SSH 公钥格式无效"
    fi
    if [ "$action" = "apply" ] && [ "$key_seen$config_seen" = "00" ]; then
        fail "没有需要执行的操作"
    fi
    require_root
    acquire_lock
    run_change "$action" "$key_value" "$key_seen" "$config_seen"
}

main "$@"
