#!/bin/bash

set -o pipefail

readonly REMOTE_URL="https://raw.githubusercontent.com/vitoegg/Provider/master/RuleSet/Extra/Firewall/telegramip.nft"
readonly NFT_TABLE="telegramip"
readonly ROOT="${TELEGRAMIP_ROOT:-/}"
readonly NFT_FILE="${ROOT%/}/etc/nftables.d/telegramip.nft"
readonly NFT_MAIN_FILE="${ROOT%/}/etc/nftables.conf"
readonly LOCK_FILE="${ROOT%/}/run/telegramip.lock"

DOWNLOAD_FILE=""
STAGE_FILE=""

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
    cat <<'EOF'
用法：
  bash telegramip.sh --apply
  bash telegramip.sh --remove
参数：
  --apply    下载并应用 Telegram IP 映射
  --remove   删除 Telegram IP 实时和持久化规则
  -h, --help 显示帮助
EOF
}

require_root() {
    if [ "$ROOT" != "/" ]; then
        return 0
    fi
    [ "$(id -u)" = "0" ] || fail "此操作必须以 root 权限运行"
}

ensure_dependencies() {
    local apt_get missing=()

    if [ "$1" = "apply" ]; then
        command -v wget >/dev/null 2>&1 || missing+=(wget)
        command -v cmp >/dev/null 2>&1 || missing+=(diffutils)
    fi
    command -v nft >/dev/null 2>&1 || missing+=(nftables)
    command -v flock >/dev/null 2>&1 || missing+=(util-linux)
    if [ "$1" = "apply" ] && [ "$ROOT" = "/" ] && [ ! -e /etc/ssl/certs/ca-certificates.crt ]; then
        missing+=(ca-certificates)
    fi
    if [ "${#missing[@]}" -gt 0 ]; then
        apt_get="${TELEGRAMIP_APT_GET:-$(command -v apt-get 2>/dev/null || true)}"
        [ -n "$apt_get" ] || fail "缺失依赖且未检测到 apt-get：${missing[*]}"
        log_info "正在安装缺失依赖：${missing[*]}"
        DEBIAN_FRONTEND=noninteractive "$apt_get" update -qq >/dev/null 2>&1 || fail "软件包索引更新失败"
        DEBIAN_FRONTEND=noninteractive "$apt_get" install -y -qq "${missing[@]}" >/dev/null 2>&1 ||
            fail "依赖安装失败：${missing[*]}"
        log_info "已安装依赖：${missing[*]}"
    fi
    if [ "$1" = "apply" ]; then
        command -v systemctl >/dev/null 2>&1 || fail "未检测到 systemd"
    fi
}

acquire_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")" || fail "无法创建锁目录"
    exec 9>"$LOCK_FILE" || fail "无法创建锁文件"
    flock -n 9 || fail "已有 Telegram IP 任务正在执行，请稍后重试"
}

ensure_nft_include() {
    if [ -f "$NFT_MAIN_FILE" ] &&
        grep -Eq '^[[:space:]]*include[[:space:]]+"?/etc/nftables[.]d/([*]|telegramip)[.]nft"?[[:space:]]*$' \
            "$NFT_MAIN_FILE"; then
        return 0
    fi
    mkdir -p "$(dirname "$NFT_MAIN_FILE")" || fail "无法创建 nftables 配置目录"
    if [ ! -e "$NFT_MAIN_FILE" ]; then
        : > "$NFT_MAIN_FILE" || fail "无法创建 nftables 主配置"
        chmod 644 "$NFT_MAIN_FILE" || fail "无法设置 nftables 主配置权限"
    fi
    if ! printf '\ninclude "/etc/nftables.d/*.nft"\n' >> "$NFT_MAIN_FILE"; then
        fail "无法写入 nftables include"
    fi
    log_info "已添加 nftables 共享持久化 include"
}

ensure_nft_service() {
    if [ "$ROOT" != "/" ]; then
        return 0
    fi
    if systemctl is-enabled --quiet nftables.service 2>/dev/null; then
        return 0
    fi
    if ! systemctl enable nftables.service >/dev/null 2>&1; then
        log_warning "nftables.service 未启用，重启后规则可能失效"
        return 0
    fi
    log_info "已启用系统服务：nftables.service"
}

nft_table_exists() {
    if nft list table ip "$NFT_TABLE" >/dev/null 2>&1; then
        return 0
    fi
    if ! nft list tables >/dev/null 2>&1; then
        return 2
    fi
    return 1
}

download_rules() {
    DOWNLOAD_FILE="$(mktemp "${TMPDIR:-/tmp}/telegramip.download.XXXXXX")" || fail "无法创建下载临时文件"
    wget -q --https-only --timeout=15 --tries=3 -O "$DOWNLOAD_FILE" "$REMOTE_URL" ||
        fail "Telegram IP 规则下载失败"
    [ -s "$DOWNLOAD_FILE" ] || fail "Telegram IP 规则内容为空"
}

apply_rules() {
    local nft_output table_status message="Telegram IP 映射已创建"
    download_rules
    nft_output="$(nft -c -f "$DOWNLOAD_FILE" 2>&1)" ||
        fail "Telegram IP 规则预检失败${nft_output:+：$nft_output}"
    grep -Eq '^[[:space:]]*table[[:space:]]+ip[[:space:]]+telegramip([[:space:]]*[{]|[[:space:]]*$)' \
        "$DOWNLOAD_FILE" || fail "Telegram IP 规则未声明目标表：table ip telegramip"

    if cmp -s "$DOWNLOAD_FILE" "$NFT_FILE" 2>/dev/null; then
        nft_table_exists
        table_status=$?
        case "$table_status" in
            0)
                message="Telegram IP 映射未变化，无需重新应用"
                ;;
            1)
                nft_output="$(nft -f "$NFT_FILE" 2>&1)" ||
                    fail "Telegram IP 实时规则恢复失败${nft_output:+：$nft_output}"
                message="Telegram IP 映射已恢复实时规则"
                ;;
            *)
                fail "无法读取 nftables 状态，未重新应用 Telegram IP 规则"
                ;;
        esac
    else
        mkdir -p "$(dirname "$NFT_FILE")" || fail "无法创建 NFT 规则目录"
        STAGE_FILE="$(mktemp "${NFT_FILE}.tmp.XXXXXX")" || fail "无法创建 NFT 候选文件"
        install -m 600 "$DOWNLOAD_FILE" "$STAGE_FILE" || fail "无法暂存 Telegram IP 规则"
        if [ -f "$NFT_FILE" ]; then
            message="Telegram IP 映射已替换"
        fi
        mv -f "$STAGE_FILE" "$NFT_FILE" || fail "无法发布 Telegram IP 规则"
        STAGE_FILE=""
        nft_output="$(nft -f "$NFT_FILE" 2>&1)" ||
            fail "Telegram IP 实时规则应用失败${nft_output:+：$nft_output}"
    fi

    ensure_nft_include
    ensure_nft_service
    log_info "$message"
}

remove_rules() {
    local table_status changed=0
    nft_table_exists
    table_status=$?
    case "$table_status" in
        0)
            nft delete table ip "$NFT_TABLE" >/dev/null 2>&1 || fail "无法删除 Telegram IP 实时规则"
            log_info "已删除 Telegram IP 实时规则"
            changed=1
            ;;
        2)
            fail "无法读取 nftables 状态，未删除 Telegram IP 规则"
            ;;
    esac
    if [ -f "$NFT_FILE" ]; then
        rm -f "$NFT_FILE" || fail "无法删除 Telegram IP 持久化规则"
        log_info "已删除 Telegram IP 持久化规则"
        changed=1
    fi
    if [ "$changed" -eq 0 ]; then
        log_info "Telegram IP 映射已不存在，无需删除"
    fi
}

cleanup() {
    rm -f "$DOWNLOAD_FILE" "$STAGE_FILE" 2>/dev/null || true
}

main() {
    case "${1:-}" in
        --apply)
            [ "$#" -eq 1 ] || fail "--apply 不支持额外参数"
            require_root
            ensure_dependencies apply
            acquire_lock
            apply_rules
            ;;
        --remove)
            [ "$#" -eq 1 ] || fail "--remove 不支持额外参数"
            require_root
            ensure_dependencies remove
            acquire_lock
            remove_rules
            ;;
        -h|--help)
            [ "$#" -eq 1 ] || fail "--help 不支持额外参数"
            show_help
            ;;
        "")
            log_error "请指定 --apply、--remove 或 --help"
            show_help
            return 1
            ;;
        *)
            log_error "未知参数：$1"
            show_help
            return 1
            ;;
    esac
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

main "$@"
