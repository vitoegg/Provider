#!/bin/bash

set -o pipefail

readonly REMOTE_URL="https://raw.githubusercontent.com/vitoegg/Provider/master/RuleSet/Extra/Firewall/telegramip.nft"
readonly NFT_TABLE="telegramip"
readonly ROOT="${TELEGRAMIP_ROOT:-/}"

DOWNLOAD_FILE=""
STAGE_FILE=""
BACKUP_FILE=""
HAD_BACKUP=0
APT_UPDATED=0

log_info() { printf '[INFO] %s\n' "$*"; }
log_warn() { printf '[WARNING] %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }
fail() { log_error "$1"; exit 1; }

path() {
    if [ "$ROOT" = "/" ]; then
        printf '%s\n' "$1"
    else
        printf '%s%s\n' "$ROOT" "$1"
    fi
}

nft_file() { path "/etc/nftables.d/telegramip.nft"; }
nft_main_file() { path "/etc/nftables.conf"; }
lock_file() { path "/run/telegramip.lock"; }

cleanup() {
    local rc=$? file cleanup_failed=0
    trap - EXIT HUP INT TERM
    for file in "$DOWNLOAD_FILE" "$STAGE_FILE" "$BACKUP_FILE"; do
        [ -n "$file" ] || continue
        rm -f "$file" 2>/dev/null || cleanup_failed=1
    done
    if [ "$cleanup_failed" -eq 1 ]; then
        log_error "临时文件或 NFT 备份清理失败"
        [ "$rc" -ne 0 ] || rc=1
    fi
    exit "$rc"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

require_root() {
    [ "$ROOT" != "/" ] && return 0
    [ "$(id -u)" = "0" ] || fail "此操作必须以 root 权限运行"
}

install_package() {
    local package="$1" apt_get
    apt_get="${TELEGRAMIP_APT_GET:-$(command -v apt-get 2>/dev/null || true)}"
    [ -n "$apt_get" ] || fail "缺失依赖包 ${package}，且未检测到 apt-get"
    if [ "$APT_UPDATED" != "1" ]; then
        DEBIAN_FRONTEND=noninteractive "$apt_get" update >/dev/null 2>&1 || fail "apt-get update 失败"
        APT_UPDATED=1
    fi
    DEBIAN_FRONTEND=noninteractive "$apt_get" install -y "$package" >/dev/null 2>&1 || fail "安装依赖失败: $package"
    log_info "已安装缺失依赖: $package"
}

ensure_command() {
    local command_name="$1" package_name="$2"
    command -v "$command_name" >/dev/null 2>&1 && return 0
    install_package "$package_name"
    command -v "$command_name" >/dev/null 2>&1 || fail "安装 ${package_name} 后仍未检测到命令: ${command_name}"
}

ensure_apply_dependencies() {
    ensure_command wget wget
    ensure_command nft nftables
    ensure_command flock util-linux
    ensure_command cmp diffutils
    if [ "$ROOT" = "/" ] && [ ! -e /etc/ssl/certs/ca-certificates.crt ]; then
        install_package ca-certificates
    fi
    command -v systemctl >/dev/null 2>&1 || fail "未检测到 systemctl"
}

ensure_remove_dependencies() {
    ensure_command nft nftables
    ensure_command flock util-linux
}

acquire_lock() {
    local file
    file="$(lock_file)"
    mkdir -p "$(dirname "$file")" || fail "无法创建锁目录"
    exec 9>"$file" || fail "无法创建锁文件"
    flock -n 9 || fail "检测到其他任务正在执行中，请稍后重试"
}

ensure_nft_include() {
    local config
    config="$(nft_main_file)"
    mkdir -p "$(dirname "$config")" || fail "无法创建 nftables 配置目录"
    touch "$config" || fail "无法访问 nftables 主配置: $config"
    grep -Eq '^[[:space:]]*include[[:space:]]+"?/etc/nftables[.]d/([*]|telegramip)[.]nft"?[[:space:]]*$' "$config" && return 0
    printf '\ninclude "/etc/nftables.d/*.nft"\n' >> "$config" || fail "无法写入 nftables include"
}

ensure_nft_service() {
    [ "$ROOT" = "/" ] || return 0
    systemctl is-enabled --quiet nftables.service 2>/dev/null && return 0
    systemctl enable nftables.service >/dev/null 2>&1 || {
        log_warn "nftables.service 未启用，重启后规则可能失效"
        return 0
    }
    log_info "已启用 nftables.service 开机自启"
}

nft_live_ready() {
    nft list table ip "$NFT_TABLE" >/dev/null 2>&1
}

download_rules() {
    DOWNLOAD_FILE="$(mktemp /tmp/telegramip.download.XXXXXX)" || fail "无法创建下载临时文件"
    wget -q --https-only --timeout=15 --tries=3 -O "$DOWNLOAD_FILE" "$REMOTE_URL" || fail "下载远程 NFT 失败"
    [ -s "$DOWNLOAD_FILE" ] || fail "远程 NFT 内容为空"
}

rollback_nft_file() {
    local target="$1"
    if [ "$HAD_BACKUP" = "1" ]; then
        mv -f "$BACKUP_FILE" "$target" || return 1
        BACKUP_FILE=""
    else
        rm -f "$target" || return 1
    fi
}

apply_rules() {
    local target nft_output action="已创建"
    target="$(nft_file)"
    download_rules
    nft_output="$(nft -c -f "$DOWNLOAD_FILE" 2>&1)" || fail "远程 NFT 预检失败${nft_output:+: $nft_output}"
    mkdir -p "$(dirname "$target")" || fail "无法创建 NFT 规则目录"
    ensure_nft_include
    ensure_nft_service

    if cmp -s "$DOWNLOAD_FILE" "$target" 2>/dev/null && nft_live_ready; then
        log_info "Telegram IP 映射未变化"
        return 0
    fi

    STAGE_FILE="${target}.tmp.$$"
    cp "$DOWNLOAD_FILE" "$STAGE_FILE" || fail "无法暂存远程 NFT"
    chmod 600 "$STAGE_FILE" || fail "无法设置 NFT 文件权限"

    BACKUP_FILE="${target}.bak.$$"
    if [ -f "$target" ]; then
        cp -p "$target" "$BACKUP_FILE" || fail "无法备份现有 NFT"
        HAD_BACKUP=1
        action="已替换"
    fi

    mv -f "$STAGE_FILE" "$target" || fail "无法安装远程 NFT"
    STAGE_FILE=""
    nft_output="$(nft -f "$target" 2>&1)" || {
        rollback_nft_file "$target" || fail "NFT 应用失败且无法恢复备份${nft_output:+: $nft_output}"
        fail "NFT 应用失败，已恢复原文件${nft_output:+: $nft_output}"
    }

    rm -f "$BACKUP_FILE" || fail "无法删除 NFT 备份: $BACKUP_FILE"
    BACKUP_FILE=""
    log_info "Telegram IP 映射${action}"
}

remove_rules() {
    local target
    target="$(nft_file)"
    if nft_live_ready; then
        nft delete table ip "$NFT_TABLE" >/dev/null 2>&1 || fail "无法删除 live NFT table: $NFT_TABLE"
        log_info "已删除 live NFT table: $NFT_TABLE"
    fi
    if [ -f "$target" ]; then
        rm -f "$target" || fail "无法删除 NFT 规则文件: $target"
        log_info "已删除 NFT 规则文件: $target"
    fi
    log_info "已保留共享 nftables include 与服务状态"
}

show_help() {
    cat << 'EOF'
Usage:
  telegramip.sh --apply
  telegramip.sh --remove
  telegramip.sh --help

Actions:
  --apply    下载远程 NFT，创建或替换 Telegram IP 映射
  --remove   删除 Telegram IP 映射和持久规则文件
  --help     显示帮助
EOF
}

main() {
    [ "${BASH_VERSINFO[0]:-0}" -ge 3 ] || fail "此脚本要求 Bash >= 3"
    case "${1:-}" in
        --apply)
            [ "$#" -eq 1 ] || fail "--apply 不支持额外参数"
            require_root
            ensure_apply_dependencies
            acquire_lock
            apply_rules
            ;;
        --remove)
            [ "$#" -eq 1 ] || fail "--remove 不支持额外参数"
            require_root
            ensure_remove_dependencies
            acquire_lock
            remove_rules
            ;;
        --help|-h)
            [ "$#" -eq 1 ] || fail "--help 不支持额外参数"
            show_help
            ;;
        "")
            log_error "请指定 --apply、--remove 或 --help"
            show_help
            exit 1
            ;;
        *)
            log_error "未知参数: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
