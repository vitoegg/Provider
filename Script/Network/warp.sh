#!/bin/bash

set -o pipefail

readonly ROOT="${WARP_ROOT:-/}"
readonly WARP_DIR="${ROOT%/}/etc/provider/warp"
readonly WARP_ACCOUNTS_DIR="${WARP_DIR}/accounts"
readonly WGCF_BIN="${WARP_DIR}/wgcf"
readonly WGCF_VERSION_FILE="${WARP_DIR}/wgcf.version"
readonly WGCF_LATEST_URL="https://github.com/ViRb3/wgcf/releases/latest"
readonly WGCF_RELEASE_BASE="https://github.com/ViRb3/wgcf/releases/download"
readonly DEVICE_MODEL="Samsung,S931U"

LICENSE=""
ACCOUNT_ID=""
DEVICE_NAME=""
ACTION="generate"
ACCOUNT_CREATED=0
WGCF_ACCOUNT=""
WGCF_PROFILE=""
WGCF_LOG=""
ACCOUNTS=()
NAMES=()
TMP_FILE=""

log_info() {
    printf '[INFO] %s\n' "$*"
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
  bash warp.sh --account ID --name NAME [--account ID --name NAME ...] [--license KEY]
  bash warp.sh --remove
参数：
  --account ID     本地账户 ID，必须和 --name 成对出现
  --name NAME      WARP 设备名称，必须紧跟对应的 --account
  --license KEY    WARP+ license，对全部账户生效
  --remove, -u     清理全部 WARP 配置和生成产物
  --help, -h       显示帮助
EOF
}

append_account_pair() {
    local account="$1" name="$2" existing
    [[ "$account" =~ ^[A-Za-z0-9._-]+$ ]] || fail "--account 只能使用字母、数字、点、下划线或横线"
    if [ "$account" = "." ] || [ "$account" = ".." ]; then
        fail "--account 不能是 . 或 .."
    fi
    [ -n "$name" ] || fail "--name 缺少参数值"
    for existing in "${ACCOUNTS[@]}"; do
        [ "$existing" != "$account" ] || fail "重复账户：$account"
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
            --account|--account=*)
                if [ "$1" = "--account" ]; then
                    [ -n "${2:-}" ] || fail "--account 缺少参数值"
                    account="$2"
                    shift 2
                else
                    account="${1#*=}"
                    [ -n "$account" ] || fail "--account 缺少参数值"
                    shift
                fi
                case "${1:-}" in
                    --name)
                        [ -n "${2:-}" ] || fail "--name 缺少参数值"
                        name="$2"
                        shift 2
                        ;;
                    --name=*)
                        name="${1#*=}"
                        [ -n "$name" ] || fail "--name 缺少参数值"
                        shift
                        ;;
                    *)
                        fail "--account $account 必须紧跟 --name NAME"
                        ;;
                esac
                append_account_pair "$account" "$name"
                ;;
            --name|--name=*)
                fail "--name 必须紧跟对应的 --account ID"
                ;;
            --license)
                [ -n "${2:-}" ] || fail "--license 缺少参数值"
                LICENSE="$2"
                shift 2
                ;;
            --license=*)
                LICENSE="${1#*=}"
                [ -n "$LICENSE" ] || fail "--license 缺少参数值"
                shift
                ;;
            *)
                fail "未知参数：$1"
                ;;
        esac
    done

    if [ "$ACTION" = "remove" ]; then
        if [ "${#ACCOUNTS[@]}" -gt 0 ] || [ -n "$LICENSE" ]; then
            fail "清理模式不接受 --account、--name 或 --license"
        fi
    elif [ "${#ACCOUNTS[@]}" -eq 0 ]; then
        fail "必须提供 --account ID --name NAME"
    fi
}

ensure_dependencies() {
    local missing=()
    if [ "$ROOT" != "/" ]; then
        return 0
    fi
    command -v apt-get >/dev/null 2>&1 || fail "仅支持 Debian/Ubuntu apt-get 环境"
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v sha256sum >/dev/null 2>&1 || missing+=(coreutils)
    dpkg-query -W -f='${db:Status-Abbrev}' ca-certificates 2>/dev/null | grep -q '^ii ' ||
        missing+=(ca-certificates)
    [ "${#missing[@]}" -gt 0 ] || return 0

    log_info "正在安装缺失依赖：${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || fail "软件包索引更新失败"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1 ||
        fail "依赖安装失败：${missing[*]}"
    log_info "已安装依赖：${missing[*]}"
}

detect_arch() {
    local machine
    local -A arch_by_machine=(
        [x86_64]="amd64"
        [amd64]="amd64"
        [aarch64]="arm64"
        [arm64]="arm64"
        [i386]="386"
        [i686]="386"
        [armv7l]="armv7"
        [armv6l]="armv6"
        [armv5l]="armv5"
    )
    machine="$(uname -m)"
    if [[ "$machine" =~ ^armv([567]) ]]; then
        machine="armv${BASH_REMATCH[1]}l"
    fi
    [ -n "${arch_by_machine[$machine]:-}" ] || return 1
    printf '%s\n' "${arch_by_machine[$machine]}"
}

ensure_wgcf() {
    local latest_url tag version arch asset url current=""
    local expected_hash=""
    install -d -m 700 "$WARP_DIR" || fail "无法创建 WARP 目录"
    latest_url="$(curl -fsSLI --retry 3 --connect-timeout 10 --max-time 30 -o /dev/null -w '%{url_effective}' \
        "$WGCF_LATEST_URL")" || fail "无法获取 wgcf 最新版本"
    tag="${latest_url##*/}"
    [[ "$tag" == v* ]] || fail "无法识别 wgcf 最新版本"
    if [ -f "$WGCF_VERSION_FILE" ]; then
        if ! current="$(cat "$WGCF_VERSION_FILE" 2>/dev/null)"; then
            current=""
        fi
    fi
    if [ -x "$WGCF_BIN" ] && [ "$current" = "$tag" ]; then
        return 0
    fi

    version="${tag#v}"
    arch="$(detect_arch)" || fail "不支持的系统架构：$(uname -m)"
    asset="wgcf_${version}_linux_${arch}"
    url="${WGCF_RELEASE_BASE}/${tag}/${asset}"
    TMP_FILE="$(mktemp "${WARP_DIR}/wgcf.tmp.XXXXXX")" || fail "无法创建 wgcf 候选文件"
    log_info "正在下载 wgcf：${tag}"
    if ! curl -fsSL --retry 3 --connect-timeout 10 --max-time 120 -o "$TMP_FILE" "$url"; then
        fail "wgcf 下载失败"
    fi
    [ -s "$TMP_FILE" ] || fail "wgcf 下载内容为空"
    expected_hash="$(
        curl -fsSL --retry 3 --connect-timeout 10 --max-time 30 \
            "${WGCF_RELEASE_BASE}/${tag}/checksums.txt" |
            awk -v asset="$asset" '$2 == asset { print $1; matches++ } END { exit matches != 1 }'
    )" || fail "wgcf 官方校验值获取失败"
    [[ "$expected_hash" =~ ^[[:xdigit:]]{64}$ ]] || fail "wgcf 官方校验值无效"
    printf '%s  %s\n' "$expected_hash" "$TMP_FILE" | sha256sum -c - >/dev/null 2>&1 ||
        fail "wgcf SHA-256 校验失败"
    chmod 755 "$TMP_FILE" || fail "无法设置 wgcf 权限"
    "$TMP_FILE" --help >/dev/null 2>&1 || fail "wgcf 候选文件无法执行"
    mv -f "$TMP_FILE" "$WGCF_BIN" || fail "无法安装 wgcf"
    TMP_FILE=""
    printf '%s\n' "$tag" > "$WGCF_VERSION_FILE" || fail "无法写入 wgcf 版本"
    log_info "已安装 wgcf：${tag}"
}

run_wgcf() {
    (
        cd "$(dirname "$WGCF_ACCOUNT")" || exit 1
        "$WGCF_BIN" "$@"
    ) >> "$WGCF_LOG" 2>&1
}

register_account_if_needed() {
    if [ -s "$WGCF_ACCOUNT" ]; then
        return 0
    fi
    [ -n "$DEVICE_NAME" ] || fail "首次注册必须提供 --name"
    log_info "正在注册 WARP 账户：${ACCOUNT_ID}"
    run_wgcf register --name "$DEVICE_NAME" --model "$DEVICE_MODEL" --accept-tos ||
        fail "WARP 账户注册失败，请检查：$WGCF_LOG"
    [ -s "$WGCF_ACCOUNT" ] || fail "WARP 账户文件未生成：${ACCOUNT_ID}"
    chmod 600 "$WGCF_ACCOUNT" || fail "无法设置 WARP 账户文件权限"
    ACCOUNT_CREATED=1
    log_info "已注册 WARP 账户：${ACCOUNT_ID}"
}

update_account_if_needed() {
    local args=()

    if [ "$ACCOUNT_CREATED" != "1" ] && [ -n "$DEVICE_NAME" ]; then
        args+=(--name "$DEVICE_NAME")
    fi
    if [ -n "$LICENSE" ]; then
        args+=(--license-key "$LICENSE")
    fi
    if [ "${#args[@]}" -eq 0 ]; then
        return 0
    fi
    run_wgcf update "${args[@]}" || fail "WARP 账户更新失败，请检查：$WGCF_LOG"
    chmod 600 "$WGCF_ACCOUNT" || fail "无法设置 WARP 账户文件权限"
    log_info "已更新 WARP 账户：${ACCOUNT_ID}"
}

generate_profile() {
    TMP_FILE="$(mktemp "${WGCF_PROFILE}.tmp.XXXXXX")" || fail "无法创建 WARP 配置候选文件"
    if run_wgcf generate --profile "$TMP_FILE" &&
       [ -s "$TMP_FILE" ] && chmod 600 "$TMP_FILE" &&
       mv -f "$TMP_FILE" "$WGCF_PROFILE"; then
        TMP_FILE=""
        log_info "已生成 WARP 配置：${ACCOUNT_ID}"
        return 0
    fi
    rm -f "$TMP_FILE" || fail "WARP 配置生成失败且无法清理候选文件：$TMP_FILE"
    TMP_FILE=""
    fail "WARP 配置生成失败，请检查：$WGCF_LOG"
}

generate_all() {
    local i account_dir

    ensure_dependencies
    ensure_wgcf
    for ((i = 0; i < ${#ACCOUNTS[@]}; i++)); do
        ACCOUNT_ID="${ACCOUNTS[$i]}"
        DEVICE_NAME="${NAMES[$i]}"
        ACCOUNT_CREATED=0
        account_dir="${WARP_ACCOUNTS_DIR}/${ACCOUNT_ID}"
        WGCF_ACCOUNT="${account_dir}/wgcf-account.toml"
        WGCF_PROFILE="${account_dir}/wgcf-profile.conf"
        WGCF_LOG="${account_dir}/wgcf.log"
        install -d -m 700 "$account_dir" || fail "无法创建 WARP 账户目录：$ACCOUNT_ID"
        : > "$WGCF_LOG" || fail "无法写入 WARP 日志：${ACCOUNT_ID}"
        chmod 600 "$WGCF_LOG" || fail "无法设置 WARP 日志权限"
        register_account_if_needed
        update_account_if_needed
        generate_profile
        printf '\n配置位置：%s\n' "$WGCF_PROFILE"
        printf '%s\n' '----- WARP CONFIG BEGIN -----'
        cat "$WGCF_PROFILE" || fail "无法读取 WARP 配置"
        printf '%s\n' '----- WARP CONFIG END -----'
    done
}

remove_all() {
    if [ ! -d "$WARP_DIR" ]; then
        log_info "WARP 产物已不存在，无需清理"
        return 0
    fi
    rm -rf "$WARP_DIR" || fail "无法删除 WARP 产物目录"
    log_info "已删除 WARP 产物目录"
}

main() {
    parse_args "$@"
    if [ "$ROOT" = "/" ] && [ "$(id -u)" != "0" ]; then
        fail "此操作必须以 root 权限运行"
    fi
    if [ "$ACTION" = "remove" ]; then
        remove_all
    else
        generate_all
    fi
}

trap 'rm -f "$TMP_FILE"' EXIT

main "$@"
