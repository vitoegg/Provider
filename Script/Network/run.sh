#!/usr/bin/env bash
set -Eeuo pipefail

PROVIDER_SCRIPT_DIR="/root"
PLAN_FILE=""
LOG_FILE=""
CLEARED_SERVICES=""

log() { printf '[RUN] %s\n' "$*" >&2; }
fail() {
  printf '[RUN] FAIL %s\n' "$*" >&2
  exit 1
}

cleanup_runtime() {
  local status=$?
  if [ "$status" -ne 0 ] && [ -n "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
    log "error output | first_lines=20"
    head -n 20 "$LOG_FILE" >&2 || true
  fi
  [ -z "$LOG_FILE" ] || rm -f "$LOG_FILE" || true
  return "$status"
}
trap cleanup_runtime EXIT

run_quiet() {
  [ -n "$LOG_FILE" ] || LOG_FILE="$(mktemp /tmp/cloud-run.XXXXXX)"
  "$@" >"$LOG_FILE" 2>&1 || return
  : >"$LOG_FILE"
}

mark_cleared() { CLEARED_SERVICES="${CLEARED_SERVICES}${CLEARED_SERVICES:+,}${1}"; }

require_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || fail "root required"
}

require_apt() {
  command -v apt-get >/dev/null 2>&1 || fail "Debian/Ubuntu apt required"
}

has_pkg() {
  case "$1" in
    systemd-timesyncd) dpkg-query -W -f='${db:Status-Abbrev}' systemd-timesyncd 2>/dev/null | grep -q '^ii ' ;;
    *) command -v "$1" >/dev/null 2>&1 ;;
  esac
}

install_packages() {
  env DEBIAN_FRONTEND=noninteractive apt-get update -qq
  env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
}

ensure_packages() {
  local missing=() package
  for package in "$@"; do
    has_pkg "$package" || missing+=("$package")
  done
  [ "${#missing[@]}" -eq 0 ] && return 0
  run_quiet install_packages "${missing[@]}" || fail "dependency install failed | packages=${missing[*]}"
}

script_path() {
  local path="${PROVIDER_SCRIPT_DIR}/${1}"
  [ -s "$path" ] || fail "provider script missing | path=${path}"
  printf '%s' "$path"
}

service_active() {
  systemctl is-active --quiet "$1" >/dev/null 2>&1
}

provider_run() {
  local script="$1" path
  shift
  path="$(script_path "$script")"
  run_quiet bash "$path" "$@"
}

allowlist_count() {
  printf '%s\n' "$1" | awk -F, '
    {
      for (i = 1; i <= NF; i++) {
        item = $i
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
        if (item == "") continue
        total++
      }
      printf "%d", total
    }'
}

step_ssh_guard() {
  [ "$#" -ge 2 ] && [ "$#" -le 3 ] || fail "step_ssh_guard requires script, allowlist, and optional public key"
  local script="$1" allowlist="$2" public_key="${3:-}" allow_count key_detail=""
  local -a args
  [ -n "$allowlist" ] || fail "ssh allowlist empty"

  args=(--reset config=ssh "allow=${allowlist}")
  if [ -n "$public_key" ]; then
    args+=("key=${public_key}")
    key_detail=" | root_key=ready"
  fi

  allow_count="$(allowlist_count "$allowlist")"
  provider_run "$script" "${args[@]}" || fail "ssh guard failed | trusted_sources=${allow_count}"
  log "ssh guard enabled | trusted_sources=${allow_count}${key_detail}"
}

update_hosts() {
  if grep -q '^127\.0\.1\.1[[:space:]]' /etc/hosts 2>/dev/null; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1 ${1}/" /etc/hosts
  else
    printf '127.0.1.1 %s\n' "$1" >> /etc/hosts
  fi
}

step_hostname() {
  [ "$#" -eq 1 ] || fail "step_hostname requires hostname"
  local target="$1" current
  current="$(hostname 2>/dev/null || true)"
  if [ "$current" = "$target" ] && grep -Eq "^127\\.0\\.1\\.1[[:space:]]+${target}$" /etc/hosts 2>/dev/null; then
    log "hostname configured | name=${target}"
    return 0
  fi
  run_quiet hostnamectl set-hostname "$target" || fail "hostname configuration failed | name=${target}"
  run_quiet update_hosts "$target" || fail "hosts file update failed | name=${target}"
  log "hostname configured | name=${target}"
}

current_timezone() {
  timedatectl show --property=Timezone --value 2>/dev/null || true
}

step_time_sync() {
  local timezone="${1:-}" service="${2:-}" synced="" i
  [ "$#" -eq 2 ] || fail "step_time_sync requires timezone and service"
  [ "$service" = "systemd-timesyncd" ] || fail "unsupported time sync service | service=${service}"

  ensure_packages systemd-timesyncd
  if [ "$(current_timezone)" != "$timezone" ]; then
    run_quiet timedatectl set-timezone "$timezone" || fail "timezone configuration failed | timezone=${timezone}"
  fi

  run_quiet systemctl enable --now systemd-timesyncd || fail "time sync start failed | service=systemd-timesyncd"
  [ "$(current_timezone)" = "$timezone" ] || fail "timezone verification failed | timezone=${timezone}"
  systemctl is-enabled --quiet systemd-timesyncd 2>/dev/null || fail "time sync not enabled | service=systemd-timesyncd"
  service_active systemd-timesyncd || fail "time sync inactive | service=systemd-timesyncd"

  for i in $(seq 1 30); do
    synced="$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || true)"
    [ "$synced" = "yes" ] && break
    sleep 2
  done
  [ "$synced" = "yes" ] || fail "time sync not synchronized | service=systemd-timesyncd"

  log "time sync active | timezone=${timezone} | synchronized=yes"
}

step_proxy() {
  [ "$#" -ge 3 ] || fail "step_proxy requires owner, script, and configuration arguments"
  local owner="$1" script="$2"
  shift 2
  provider_run "$script" "$@" || fail "proxy configuration failed | owner=${owner}"
  log "proxy configured | owner=${owner}"
}

step_proxy_remove() {
  [ "$#" -ge 3 ] || fail "step_proxy_remove requires owner, script, and removal arguments"
  local owner="$1" script="$2"
  shift 2
  provider_run "$script" "$@" || fail "proxy removal failed | owner=${owner}"
  mark_cleared "$owner"
}

step_kernel() {
  [ "$#" -ge 1 ] || fail "step_kernel requires script"
  local script="$1"
  shift
  provider_run "$script" "$@" || fail "kernel tuning configuration failed"
  if [ "${1:-}" = "-u" ]; then mark_cleared kernel; else log "kernel tuning configured"; fi
}

step_dns_remove() {
  [ "$#" -ge 3 ] || fail "step_dns_remove requires owner, script, and removal arguments"
  local owner="$1" script="$2"
  shift 2
  provider_run "$script" "$@" || fail "dns resolver removal failed | owner=${owner}"
  mark_cleared "$owner"
}

step_dns() {
  [ "$#" -ge 2 ] || fail "step_dns requires owner and script"
  local owner="$1" script="$2"
  shift 2
  provider_run "$script" "$@" || fail "dns resolver configuration failed | owner=${owner}"
  log "dns resolver configured | owner=${owner}"
}

step_traffic() {
  [ "$#" -ge 2 ] || fail "step_traffic requires mode and script"
  local mode="$1" script="$2"
  shift 2
  case "$mode" in
    forward)
      provider_run "$script" -r "$@" || fail "traffic rules load failed | mode=forward"
      log "traffic rules loaded | mode=forward"
      ;;
    protect)
      provider_run "$script" --protect on "$@" || fail "traffic rules load failed | mode=protect"
      log "traffic rules loaded | mode=protect"
      ;;
    off)
      [ "$#" -eq 0 ] || fail "traffic off does not accept arguments"
      provider_run "$script" -u || fail "traffic rules removal failed"
      mark_cleared traffic
      ;;
    *)
      fail "unknown traffic mode | mode=${mode}"
      ;;
  esac
}

step_cleanup_scripts() {
  local script
  for script in "$@"; do
    case "$script" in
      ""|*/*) fail "invalid cleanup script | name=${script}" ;;
    esac
    if [ -e "${PROVIDER_SCRIPT_DIR}/${script}" ]; then
      rm -f "${PROVIDER_SCRIPT_DIR}/${script}" || fail "provider script cleanup failed | script=${script}"
    fi
  done
}

run_plan() {
  [ -r "$PLAN_FILE" ] || fail "plan unreadable | file=${PLAN_FILE}"
  # shellcheck disable=SC1090
  source "$PLAN_FILE"
  [ -z "$CLEARED_SERVICES" ] || log "services cleared | names=${CLEARED_SERVICES}"
}

main() {
  case "${1:-}" in
    -h|--help)
      printf 'Usage: bash run.sh /path/to/cloudserver.plan\n'
      exit 0
      ;;
  esac
  [ -n "${1:-}" ] || { printf 'Usage: bash run.sh /path/to/cloudserver.plan\n' >&2; exit 1; }
  PLAN_FILE="$1"
  require_root
  require_apt
  run_plan
}

main "$@"
