#!/usr/bin/env bash
set -Eeuo pipefail

API_URL="https://api.github.com/repos/pymumu/smartdns/releases/latest"
CONFIG_DIR="/etc/smartdns"
CONFIG_FILE="${CONFIG_DIR}/smartdns.conf"
INSTALLER_CACHE="${CONFIG_DIR}/install"
RESOLV_CONF="/etc/resolv.conf"

ARCH_TYPE=""
DOWNLOAD_URL=""
ECS_REGION=""
IPV6_MODE=""
UNINSTALL=0

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage:
  bash smartdns.sh [--ecs REGION] [-6|--ipv6 yes|no]
  bash smartdns.sh -u|--uninstall

Options:
  -e, --ecs REGION        ECS region: HK, TYO, LA, OR, SEA
  -6, --ipv6 MODE         IPv6 mode: yes, no
  -u, --uninstall         Uninstall SmartDNS and restore public DNS
  -h, --help              Show help
EOF
}

ecs_ip() {
  case "$1" in
    HK) printf '42.2.2.2' ;;
    TYO) printf '106.152.210.210' ;;
    LA) printf '107.119.53.53' ;;
    OR) printf '12.75.216.200' ;;
    SEA) printf '68.86.93.93' ;;
    *) return 1 ;;
  esac
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      -u|--uninstall) UNINSTALL=1; shift ;;
      -e|--ecs)
        [ -n "${2:-}" ] && [[ "${2:-}" != -* ]] || fail "ECS region required"
        ECS_REGION="$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"
        ecs_ip "$ECS_REGION" >/dev/null || fail "invalid ECS region: $2"
        shift 2
        ;;
      -6|--ipv6)
        case "${2:-}" in
          yes|no) IPV6_MODE="$2" ;;
          *) fail "invalid IPv6 mode: ${2:-}" ;;
        esac
        shift 2
        ;;
      *) usage >&2; fail "unknown argument: $1" ;;
    esac
  done
}

require_root_systemd() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || fail "root required"
  command -v systemctl >/dev/null 2>&1 || fail "systemd required"
}

ensure_dependencies() {
  command -v apt-get >/dev/null 2>&1 || fail "Debian/Ubuntu apt required"
  local missing=()
  command -v jq >/dev/null 2>&1 || missing+=(jq)
  command -v tar >/dev/null 2>&1 || missing+=(tar)
  command -v ss >/dev/null 2>&1 || missing+=(iproute2)
  command -v wget >/dev/null 2>&1 || missing+=(wget)
  [ -e /etc/ssl/certs/ca-certificates.crt ] || missing+=(ca-certificates)

  if [ "${#missing[@]}" -gt 0 ]; then
    log "Installing dependencies: ${missing[*]}"
    env DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null ||
      fail "dependency metadata update failed"
    env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null ||
      fail "dependency install failed"
  fi
}

fetch() {
  wget -qO- "$1"
}

download() {
  wget -q -O "$2" "$1"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64) ARCH_TYPE="x86_64" ;;
    aarch64) ARCH_TYPE="aarch64" ;;
    *) fail "unsupported architecture: $(uname -m)" ;;
  esac
}

select_release_asset() {
  local json tag
  json="$(fetch "$API_URL")" || fail "failed to fetch SmartDNS release"
  tag="$(printf '%s' "$json" | jq -r '.tag_name // empty')"
  [ -n "$tag" ] || fail "failed to parse SmartDNS release tag"

  DOWNLOAD_URL="$(
    printf '%s' "$json" |
      jq -r --arg arch "$ARCH_TYPE" '
        .assets[]
        | select(.name | test("^smartdns\\..*\\." + $arch + "-linux-all\\.tar\\.gz$"))
        | .browser_download_url
      ' | head -n 1
  )"
  [ -n "$DOWNLOAD_URL" ] || fail "failed to find SmartDNS linux tar asset"
  log "SmartDNS release: ${tag}"
}

service_exists() {
  systemctl cat smartdns.service >/dev/null 2>&1 && return 0
  systemctl list-unit-files smartdns.service 2>/dev/null |
    awk '$1=="smartdns.service" { found=1 } END { exit !found }'
}

smartdns_present() {
  service_exists || [ -x /usr/sbin/smartdns ] || [ -e "$CONFIG_FILE" ]
}

port_53_conflict() {
  ss -H -lunp 2>/dev/null | awk '
    function port_matches(addr) {
      return addr ~ /(^|\[::\]|0\.0\.0\.0|127\.0\.0\.1|\*):53$/
    }
    port_matches($4) || port_matches($5) { found=1 }
    END { exit !found }
  '
}

smartdns_listening() {
  ss -H -lunp 2>/dev/null | awk '
    function port_matches(addr) {
      return addr ~ /(^|\[::\]|0\.0\.0\.0|127\.0\.0\.1|\*):53$/
    }
    port_matches($4) || port_matches($5) { found=1 }
    END { exit !found }
  '
}

run_installer() {
  local action="$1" tmp_dir
  tmp_dir="$(mktemp -d)"
  if ! (
    cd "$tmp_dir"
    download "$DOWNLOAD_URL" smartdns.tar.gz
    tar zxf smartdns.tar.gz
    cd smartdns
    chmod +x ./install
    ./install "$action" >/dev/null 2>&1
    if [ "$action" = "-i" ]; then
      mkdir -p "$CONFIG_DIR"
      cp ./install "$INSTALLER_CACHE"
      chmod 755 "$INSTALLER_CACHE"
    fi
  ); then
    rm -rf "$tmp_dir"
    fail "SmartDNS installer failed: ${action}"
  fi
  rm -rf "$tmp_dir"
}

write_config() {
  local suffix="" ip
  mkdir -p "$CONFIG_DIR"
  if [ -n "$ECS_REGION" ]; then
    ip="$(ecs_ip "$ECS_REGION")"
    suffix=" -subnet ${ip}/24"
    log "ECS: ${ECS_REGION} (${ip})"
  fi

  cat > "$CONFIG_FILE" <<EOF
server-name smartdns
log-level off
bind 127.0.0.1:53
server 1.1.1.1
server 45.11.45.11
server 8.8.8.8${suffix}
server 94.140.14.140${suffix}
speed-check-mode ping,tcp:80,tcp:443
serve-expired yes
serve-expired-ttl 129600
serve-expired-reply-ttl 1
prefetch-domain yes
serve-expired-prefetch-time 21600
cache-size 4096
cache-persist yes
cache-file /etc/smartdns/smartdns.cache
force-qtype-SOA 65
EOF

  case "$IPV6_MODE" in
    no) printf 'dualstack-ip-selection no\nforce-AAAA-SOA yes\n' >> "$CONFIG_FILE" ;;
    yes) printf 'dualstack-ip-selection yes\n' >> "$CONFIG_FILE" ;;
  esac
}

set_dns() {
  chattr -i "$RESOLV_CONF" 2>/dev/null || true
  rm -f "$RESOLV_CONF"
  if [ "$1" = "local" ]; then
    printf 'nameserver 127.0.0.1\n' > "$RESOLV_CONF"
    chattr +i "$RESOLV_CONF" 2>/dev/null || true
  else
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$RESOLV_CONF"
  fi
}

install_smartdns() {
  smartdns_present && fail "SmartDNS already exists; run uninstall first"
  port_53_conflict && fail "port 53 is already used by another service"

  detect_arch
  select_release_asset
  log "Installing SmartDNS..."
  run_installer -i
  write_config
  systemctl enable smartdns.service >/dev/null || fail "failed to enable SmartDNS"
  systemctl restart smartdns.service || fail "failed to restart SmartDNS"
  set_dns local

  systemctl is-active --quiet smartdns.service || fail "SmartDNS service inactive"
  systemctl is-enabled --quiet smartdns.service || fail "SmartDNS service not enabled"
  smartdns_listening || fail "SmartDNS is not listening on port 53"
  grep -qx 'nameserver 127.0.0.1' "$RESOLV_CONF" || fail "system DNS not pointed to SmartDNS"
  log "SmartDNS installed"
}

uninstall_smartdns() {
  log "Restoring public DNS..."
  set_dns public

  if smartdns_present; then
    log "Uninstalling SmartDNS..."
    if [ -x "$INSTALLER_CACHE" ]; then
      "$INSTALLER_CACHE" -u >/dev/null 2>&1 || fail "SmartDNS uninstall failed"
    else
      ensure_dependencies
      detect_arch
      select_release_asset
      run_installer -u
    fi
    rm -rf "$CONFIG_DIR"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl is-active --quiet smartdns.service 2>/dev/null && fail "SmartDNS service still active"
  else
    warn "SmartDNS not installed"
  fi

  grep -qx 'nameserver 1.1.1.1' "$RESOLV_CONF" || fail "public DNS restore failed"
  grep -qx 'nameserver 8.8.8.8' "$RESOLV_CONF" || fail "public DNS restore failed"
  log "SmartDNS uninstalled"
}

main() {
  parse_args "$@"
  require_root_systemd
  if [ "$UNINSTALL" -eq 1 ]; then
    uninstall_smartdns
  else
    ensure_dependencies
    install_smartdns
  fi
}

main "$@"
