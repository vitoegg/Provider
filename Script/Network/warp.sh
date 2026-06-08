#!/bin/bash

set -Eeuo pipefail

ROOT="${WARP_ROOT:-/}"

path() {
    if [ "$ROOT" = "/" ]; then
        printf '%s\n' "$1"
    else
        printf '%s%s\n' "$ROOT" "$1"
    fi
}

WARP_DIR="$(path "/etc/provider/warp")"
WARP_ACCOUNTS_DIR="${WARP_DIR}/accounts"
WGCF_BIN="${WARP_DIR}/wgcf"
WGCF_VERSION_FILE="${WARP_DIR}/wgcf.version"
WGCF_ACCOUNT=""
WGCF_PROFILE=""
WGCF_LOG=""
WGCF_LATEST_URL="https://github.com/ViRb3/wgcf/releases/latest"
WGCF_RELEASE_BASE="https://github.com/ViRb3/wgcf/releases/download"

LICENSE=""
ACCOUNT_ID=""
DEVICE_NAME=""
DEVICE_MODEL="Samsung,S931U"
ACTION="generate"
ACCOUNT_CREATED=0
ACCOUNTS=()
NAMES=()
TMP_FILES=()

log() { printf '[%s] %s\n' "$1" "$2"; }
info() { log "INFO" "$1"; }
ok() { log "OK" "$1"; }
fail() { log "ERR" "$1" >&2; exit 1; }

cleanup_tmp() {
    local file
    for file in "${TMP_FILES[@]:-}"; do
        [ -n "$file" ] && rm -f "$file" 2>/dev/null || true
    done
}
trap cleanup_tmp EXIT

show_help() {
    cat << EOF
Usage:
  bash warp.sh --account ID --name NAME [--account ID --name NAME ...] [--license KEY]
  bash warp.sh --remove

Options:
  --account ID     本地账户 ID，必须和 --name 成对出现
  --name NAME      WARP 设备名称，必须紧跟对应的 --account
  --license KEY    WARP+ license，对全部 account 生效
  --remove, -u     清理全部 WARP 配置和生成产物
  --help, -h       显示帮助
EOF
}

require_root() {
    [ "$ROOT" != "/" ] && return 0
    [ "$(id -u)" = "0" ] || fail "此操作必须以 root 权限运行"
}

require_apt() {
    [ "$ROOT" != "/" ] && return 0
    command -v apt-get >/dev/null 2>&1 || fail "仅支持 apt 环境"
}

ensure_deps() {
    local missing=()
    [ "$ROOT" != "/" ] && return 0
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    dpkg -s ca-certificates >/dev/null 2>&1 || missing+=("ca-certificates")
    [ "${#missing[@]}" -eq 0 ] && return 0

    info "安装依赖: ${missing[*]}"
    apt-get update -qq >/dev/null || fail "apt update 失败"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null || fail "依赖安装失败: ${missing[*]}"
}

need_value() {
    local key="$1" value="${2:-}"
    [ -n "$value" ] || fail "$key 需要参数值"
    printf '%s\n' "$value"
}

validate_account_id() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || fail "--account 只能使用字母、数字、点、下划线或横线"
    [ "$1" != "." ] && [ "$1" != ".." ] || fail "--account 不能是 . 或 .."
}

append_account_pair() {
    local account="$1" name="$2" existing
    validate_account_id "$account"
    [ -n "$name" ] || fail "--name 需要参数值"
    for existing in "${ACCOUNTS[@]:-}"; do
        [ "$existing" != "$account" ] || fail "重复 account: $account"
    done
    ACCOUNTS+=("$account")
    NAMES+=("$name")
}

parse_args() {
    local account name
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help|help)
                show_help
                exit 0
                ;;
            -u|--remove|--uninstall|remove|uninstall)
                ACTION="remove"
                shift
                ;;
            --account)
                account="$(need_value "$1" "${2:-}")"
                shift 2
                case "${1:-}" in
                    --name)
                        name="$(need_value "$1" "${2:-}")"
                        shift 2
                        ;;
                    --name=*)
                        name="${1#*=}"
                        [ -n "$name" ] || fail "--name 需要参数值"
                        shift
                        ;;
                    *)
                        fail "--account $account 必须紧跟 --name NAME"
                        ;;
                esac
                append_account_pair "$account" "$name"
                ;;
            --account=*)
                account="${1#*=}"
                [ -n "$account" ] || fail "--account 需要参数值"
                shift
                case "${1:-}" in
                    --name)
                        name="$(need_value "$1" "${2:-}")"
                        shift 2
                        ;;
                    --name=*)
                        name="${1#*=}"
                        [ -n "$name" ] || fail "--name 需要参数值"
                        shift
                        ;;
                    *)
                        fail "--account $account 必须紧跟 --name NAME"
                        ;;
                esac
                append_account_pair "$account" "$name"
                ;;
            --name|--name=*)
                fail "--name 必须紧跟在对应的 --account ID 后"
                ;;
            --license)
                LICENSE="$(need_value "$1" "${2:-}")"
                shift 2
                ;;
            --license=*)
                LICENSE="${1#*=}"
                [ -n "$LICENSE" ] || fail "--license 需要参数值"
                shift
                ;;
            *)
                fail "未知参数: $1"
                ;;
        esac
    done

    if [ "$ACTION" = "remove" ] && { [ "${#ACCOUNTS[@]}" -gt 0 ] || [ -n "$LICENSE" ]; }; then
        fail "清理模式不接受 --account、--name 或 --license"
    fi
    [ "$ACTION" = "remove" ] || [ "${#ACCOUNTS[@]}" -gt 0 ] || fail "必须提供 --account ID --name NAME"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'amd64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        i386|i686) printf '386\n' ;;
        armv7l|armv7*) printf 'armv7\n' ;;
        armv6l|armv6*) printf 'armv6\n' ;;
        armv5l|armv5*) printf 'armv5\n' ;;
        *) fail "不支持的架构: $(uname -m)" ;;
    esac
}

latest_wgcf_tag() {
    local url tag
    url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$WGCF_LATEST_URL")" || fail "无法获取 wgcf 最新版本"
    tag="${url##*/}"
    [[ "$tag" == v* ]] || fail "无法识别 wgcf 最新版本: $url"
    printf '%s\n' "$tag"
}

ensure_dirs() {
    install -d -m 700 "$WARP_DIR" || fail "无法创建目录: $WARP_DIR"
    install -d -m 700 "$WARP_ACCOUNTS_DIR" || fail "无法创建目录: $WARP_ACCOUNTS_DIR"
}

set_account_paths() {
    local account_dir
    [ -n "$ACCOUNT_ID" ] || fail "必须提供 --account"
    account_dir="${WARP_ACCOUNTS_DIR}/${ACCOUNT_ID}"
    WGCF_ACCOUNT="${account_dir}/wgcf-account.toml"
    WGCF_PROFILE="${account_dir}/wgcf-profile.conf"
    WGCF_LOG="${account_dir}/wgcf.log"
    install -d -m 700 "$account_dir" || fail "无法创建账号目录: $account_dir"
}

ensure_wgcf() {
    local tag version arch url tmp current=""
    ensure_dirs
    tag="$(latest_wgcf_tag)"
    [ -f "$WGCF_VERSION_FILE" ] && current="$(cat "$WGCF_VERSION_FILE" 2>/dev/null || true)"
    if [ -x "$WGCF_BIN" ] && [ "$current" = "$tag" ]; then
        ok "wgcf 已存在: $tag"
        return 0
    fi

    version="${tag#v}"
    arch="$(detect_arch)"
    url="${WGCF_RELEASE_BASE}/${tag}/wgcf_${version}_linux_${arch}"
    tmp="$(mktemp /tmp/wgcf.XXXXXX)" || fail "无法创建临时文件"
    TMP_FILES+=("$tmp")

    info "下载 wgcf: $tag"
    curl -fL --retry 3 --connect-timeout 10 -o "$tmp" "$url" >/dev/null 2>&1 || fail "wgcf 下载失败: $url"
    chmod +x "$tmp" || fail "无法设置 wgcf 权限"
    install -m 755 "$tmp" "$WGCF_BIN" || fail "无法安装 wgcf: $WGCF_BIN"
    printf '%s\n' "$tag" > "$WGCF_VERSION_FILE" || fail "无法记录 wgcf 版本"
    ok "wgcf 已安装: $tag"
}

run_wgcf() {
    (cd "$(dirname "$WGCF_ACCOUNT")" && "$WGCF_BIN" "$@") >>"$WGCF_LOG" 2>&1
}

register_account_if_needed() {
    [ -s "$WGCF_ACCOUNT" ] && { ok "复用账号: $WGCF_ACCOUNT"; return 0; }
    [ -n "$DEVICE_NAME" ] || fail "首次注册必须提供 --name"
    info "注册 WARP 账号: name=$DEVICE_NAME model=$DEVICE_MODEL"
    run_wgcf register --name "$DEVICE_NAME" --model "$DEVICE_MODEL" --accept-tos || fail "账号注册失败，日志: $WGCF_LOG"
    [ -s "$WGCF_ACCOUNT" ] || fail "账号文件未生成: $WGCF_ACCOUNT"
    ACCOUNT_CREATED=1
    ok "账号已生成: $WGCF_ACCOUNT"
}

update_account_if_needed() {
    local args=()
    [ "$ACCOUNT_CREATED" = "1" ] || [ -z "$DEVICE_NAME" ] || args+=(--name "$DEVICE_NAME")
    [ -n "$LICENSE" ] && args+=(--license-key "$LICENSE")
    [ "${#args[@]}" -gt 0 ] || return 0

    info "更新 WARP 账号"
    run_wgcf update "${args[@]}" || fail "账号更新失败，日志: $WGCF_LOG"
    ok "账号已更新"
}

generate_profile() {
    rm -f "$WGCF_PROFILE"
    info "生成 WARP 配置"
    run_wgcf generate || fail "配置生成失败，日志: $WGCF_LOG"
    [ -s "$WGCF_PROFILE" ] || fail "配置文件未生成: $WGCF_PROFILE"
}

show_config() {
    printf '\n配置位置: %s\n' "$WGCF_PROFILE"
    printf '%s\n' '----- WARP CONFIG BEGIN -----'
    cat "$WGCF_PROFILE"
    printf '%s\n' '----- WARP CONFIG END -----'
}

remove_dir_if_exists() {
    local dir="$1" label="$2"
    [ -d "$dir" ] || return 0
    rm -rf "$dir" || fail "无法删除${label}: $dir"
    ok "已删除${label}: $dir"
}

remove_all() {
    require_root
    remove_dir_if_exists "$WARP_DIR" "WARP 产物目录"
    ok "清理完成"
}

generate_all() {
    local i
    require_root
    require_apt
    ensure_deps
    ensure_wgcf

    for ((i = 0; i < ${#ACCOUNTS[@]}; i++)); do
        ACCOUNT_ID="${ACCOUNTS[$i]}"
        DEVICE_NAME="${NAMES[$i]}"
        ACCOUNT_CREATED=0
        set_account_paths
        : > "$WGCF_LOG" || fail "无法写入日志: $WGCF_LOG"
        info "处理 account: $ACCOUNT_ID"
        register_account_if_needed
        update_account_if_needed
        generate_profile
        ok "配置已生成: $WGCF_PROFILE"
        show_config
    done
}

parse_args "$@"
case "$ACTION" in
    generate) generate_all ;;
    remove) remove_all ;;
esac
