#!/bin/bash
set -o pipefail
export PATH="${PATH:-}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ROOT="${NGNIX_ROOT:-/}"
ACME_EMAIL="admin@xinsight.eu.org"
DOMAIN=""
EMBY_URL=""
SECRET_PATH=""
CF_TOKEN=""
CONF_FILE="/etc/nginx/conf.d/00-emby-proxy.conf"
CERT_ROOT="/etc/nginx/ssl/emby-proxy"
ACME_HOME="/root/.acme.sh"
ACME_BIN="${ACME_HOME}/acme.sh"
POLICY_RC_CREATED=0
UPSTREAM_HOST=""
log() { printf '[%s] %s\n' "$1" "$2"; }
fail() { log "ERR" "$1" >&2; exit 1; }
path() {
    if [[ "$ROOT" == "/" ]]; then
        printf '%s\n' "$1"
    else
        printf '%s%s\n' "$ROOT" "$1"
    fi
}
show_help() {
    cat << EOF
Usage:
  bash ngnix.sh --domain DOMAIN --emby HOST --path RANDOM_PATH \\
    --cf-token TOKEN
Required:
  --domain DOMAIN          HTTPS domain for this reverse proxy
  --emby HOST              HTTPS Emby upstream host, for example emby.example.com
  --path RANDOM_PATH       Case-sensitive random path, 8-64 chars: A-Z a-z 0-9
  --cf-token TOKEN         Cloudflare API token for acme.sh dns_cf
Other:
  -h, --help               Show this help
EOF
}
need_arg() {
    [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || fail "Option $1 requires a value"
}
parse_args() {
    [[ $# -gt 0 ]] || { show_help; exit 1; }
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain) need_arg "$@"; DOMAIN="$2"; shift 2 ;;
            --emby) need_arg "$@"; EMBY_URL="$2"; shift 2 ;;
            --path) need_arg "$@"; SECRET_PATH="$2"; shift 2 ;;
            --cf-token) need_arg "$@"; CF_TOKEN="$2"; shift 2 ;;
            -h|--help) show_help; exit 0 ;;
            *) fail "Unknown option: $1" ;;
        esac
    done
}
valid_domain() {
    local value="$1"
    [[ -n "$value" && "${#value}" -le 253 ]] || return 1
    [[ "$value" != .* && "$value" != *. && "$value" != *..* ]] || return 1
    [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?([.][A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}
valid_host() {
    local value="$1"
    valid_domain "$value" || [[ "$value" =~ ^([0-9]{1,3}[.]){3}[0-9]{1,3}$ ]]
}
parse_emby_url() {
    local host
    [[ "$EMBY_URL" != *[[:space:]\{\}\\\;\'\`]* ]] || fail "Invalid --emby: unsafe character"
    host="${EMBY_URL#/}"
    host="${host%/}"
    [[ "$host" != *://* && "$host" != */* && "$host" != *@* && "$host" != *:* && -n "$host" ]] ||
        fail "Invalid --emby: expected host only, for example emby.example.com"
    valid_host "$host" || fail "Invalid Emby host: $host"
    UPSTREAM_HOST="$host"
}
validate_args() {
    DOMAIN="${DOMAIN#/}"; DOMAIN="${DOMAIN%/}"
    SECRET_PATH="${SECRET_PATH#/}"; SECRET_PATH="${SECRET_PATH%/}"
    valid_domain "$DOMAIN" || fail "Invalid --domain: $DOMAIN"
    [[ "$SECRET_PATH" =~ ^[A-Za-z0-9]{8,64}$ ]] ||
        fail "Invalid --path: use 8-64 case-sensitive chars from A-Z a-z 0-9"
    [[ -n "$CF_TOKEN" ]] || fail "Missing --cf-token"
    parse_emby_url
}
require_root() {
    [[ "$ROOT" != "/" ]] && return 0
    [[ "$(id -u)" == "0" ]] || fail "Root privileges required"
}
nginx_cmd_exists() { command -v nginx >/dev/null 2>&1; }
nginx_test() {
    nginx -t >/dev/null 2>&1
}
nginx_dump() {
    nginx -T 2>/dev/null || true
}
create_policy_rc_guard() {
    local file
    file="$(path /usr/sbin/policy-rc.d)"
    [[ -e "$file" ]] && return 0
    install -d "$(dirname "$file")" || fail "Failed to create policy-rc.d directory"
    printf '#!/bin/sh\nexit 101\n' > "$file" || fail "Failed to write policy-rc.d"
    chmod 755 "$file" || true
    POLICY_RC_CREATED=1
}
cleanup_policy_rc_guard() {
    [[ "$POLICY_RC_CREATED" == "1" ]] || return 0
    rm -f "$(path /usr/sbin/policy-rc.d)" 2>/dev/null || true
}
disable_debian_defaults() {
    local file disabled
    for file in /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf; do
        file="$(path "$file")"
        [[ -e "$file" || -L "$file" ]] || continue
        if [[ "$file" == "$(path /etc/nginx/sites-enabled/default)" ]]; then
            disabled="$(path /etc/nginx/disabled-sites/default.disabled-by-ngnix)"
            mkdir -p "$(dirname "$disabled")" || fail "Failed to create disabled nginx site directory"
        else
            disabled="${file}.disabled-by-ngnix"
        fi
        rm -f "$disabled" 2>/dev/null || true
        mv "$file" "$disabled" || fail "Failed to disable default nginx site: $file"
        log "OK" "disabled default nginx site: $file"
    done
}
ensure_nginx() {
    if nginx_cmd_exists; then
        nginx_test || fail "Current nginx config test failed; fix it before running this script"
        log "OK" "nginx ready"
        return 0
    fi
    create_policy_rc_guard
    export DEBIAN_FRONTEND=noninteractive
    log "INFO" "install nginx-light"
    apt-get update >/dev/null || fail "apt-get update failed"
    apt-get install -y --no-install-recommends nginx-light curl ca-certificates >/dev/null ||
        fail "nginx-light install failed"
    nginx_cmd_exists || fail "nginx command not found after install"
    disable_debian_defaults
    nginx_test || fail "nginx config test failed after install"
    log "OK" "nginx-light installed"
}
ensure_no_http_listener() {
    local dump
    dump="$(nginx_dump)"
    if printf '%s\n' "$dump" |
        sed 's/#.*//' |
        grep -Eq '(^|[[:space:]{])listen[[:space:]]+(\[::\]:)?80([[:space:];]|$)'; then
        fail "Detected existing nginx HTTP listener on port 80"
    fi
}
ensure_443_available() {
    local output active
    command -v ss >/dev/null 2>&1 || return 0
    output="$(ss -lntp '( sport = :443 )' 2>/dev/null || true)"
    active="$(printf '%s\n' "$output" | awk 'NR > 1 && NF { print }')"
    [[ -z "$active" ]] && return 0
    printf '%s\n' "$active" | grep -qi 'nginx' ||
        fail "Port 443 is already used by a non-nginx process"
}
ensure_no_unknown_default_443() {
    local dump conf
    dump="$(nginx_dump)"
    if ! printf '%s\n' "$dump" |
        sed 's/#.*//' |
        grep -Eq '(^|[[:space:]{])listen[[:space:]]+(\[::\]:)?443[[:space:]][^;]*default_server'; then
        return 0
    fi
    conf="$(path "$CONF_FILE")"
    [[ -f "$conf" ]] && grep -qF "Managed by Provider ngnix.sh" "$conf" ||
        fail "Detected existing nginx default_server on 443"
}
ensure_acme() {
    local bin installer
    bin="$(path "$ACME_BIN")"
    [[ -x "$bin" ]] && { log "OK" "acme.sh ready"; return 0; }
    installer="$(mktemp /tmp/ngnix-acme.XXXXXX)" || fail "Failed to create acme installer temp file"
    log "INFO" "install acme.sh"
    curl -fsSL https://get.acme.sh -o "$installer" || fail "acme.sh download failed"
    sh "$installer" email="$ACME_EMAIL" >/dev/null || fail "acme.sh install failed"
    rm -f "$installer"
    [[ -x "$bin" ]] || fail "acme.sh not found after install"
}
ensure_cert() {
    local cert_dir cert_file key_file bin reload_cmd
    cert_dir="$(path "$CERT_ROOT/$DOMAIN")"
    cert_file="${cert_dir}/fullchain.pem"
    key_file="${cert_dir}/privkey.pem"
    bin="$(path "$ACME_BIN")"
    if [[ -s "$cert_file" && -s "$key_file" ]]; then
        log "OK" "certificate ready"
        return 0
    fi
    ensure_acme
    export CF_Token="$CF_TOKEN"
    mkdir -p "$cert_dir" || fail "Failed to create certificate directory"
    reload_cmd='nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true'
    log "INFO" "issue certificate by Cloudflare DNS-01"
    "$bin" --set-default-ca --server letsencrypt >/dev/null || fail "Failed to set acme CA"
    "$bin" --register-account -m "$ACME_EMAIL" >/dev/null || true
    "$bin" --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256 >/dev/null ||
        fail "Certificate issue failed"
    "$bin" --install-cert -d "$DOMAIN" --ecc \
        --fullchain-file "$cert_file" \
        --key-file "$key_file" \
        --reloadcmd "$reload_cmd" >/dev/null || fail "Certificate install failed"
    chmod 600 "$key_file" 2>/dev/null || true
    log "OK" "certificate installed"
}
render_nginx_conf() {
    local out="$1" reject_handshake="$2" cert_dir cert_file key_file
    cert_dir="$CERT_ROOT/$DOMAIN"
    cert_file="$cert_dir/fullchain.pem"
    key_file="$cert_dir/privkey.pem"
    cat > "$out" << EOF
# Managed by Provider ngnix.sh
map \$http_upgrade \$emby_connection_upgrade {
    default upgrade;
    '' '';
}
limit_req_zone \$binary_remote_addr zone=emby_bad_req:1m rate=1r/m;
limit_conn_zone \$binary_remote_addr zone=emby_bad_conn:1m;
upstream emby_upstream {
    server ${UPSTREAM_HOST}:443;
    keepalive 16;
}
server {
    listen 443 ssl default_server;
    server_name _;
    access_log off;
    error_log /dev/null crit;
EOF
    if [[ "$reject_handshake" == "1" ]]; then
        cat >> "$out" << 'EOF'
    ssl_reject_handshake on;
}
EOF
    else
        cat >> "$out" << EOF
    ssl_certificate ${cert_file};
    ssl_certificate_key ${key_file};
    return 444;
}
EOF
    fi
    cat >> "$out" << EOF
server {
    listen 443 ssl;
    server_name ${DOMAIN};
    ssl_certificate ${cert_file};
    ssl_certificate_key ${key_file};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:emby_ssl:10m;
    ssl_session_timeout 1d;
    ssl_prefer_server_ciphers off;
    access_log off;
    error_log /dev/null crit;
    gzip off;
    client_max_body_size 0;
    proxy_cache off;
    location = /${SECRET_PATH} {
        return 302 /${SECRET_PATH}/web/index.html;
    }
    location ^~ /${SECRET_PATH}/ {
        rewrite ^/${SECRET_PATH}(/.*)\$ \$1 break;
        proxy_pass https://emby_upstream;
        proxy_http_version 1.1;
EOF
    cat >> "$out" << EOF
        proxy_ssl_server_name on;
        proxy_ssl_name ${UPSTREAM_HOST};
        proxy_ssl_verify on;
        proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
        proxy_ssl_verify_depth 3;
EOF
    cat >> "$out" << EOF
        proxy_set_header Host ${UPSTREAM_HOST};
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$emby_connection_upgrade;
        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;
        proxy_set_header X-Real-IP "";
        proxy_set_header X-Forwarded-For "";
        proxy_set_header X-Forwarded-Proto "";
        proxy_set_header X-Forwarded-Host "";
        proxy_set_header Forwarded "";
        proxy_set_header Via "";
        proxy_redirect / /${SECRET_PATH}/;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_max_temp_file_size 0;
        proxy_force_ranges on;
        proxy_connect_timeout 30s;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        send_timeout 3600s;
    }
    location / {
        limit_req zone=emby_bad_req burst=1 nodelay;
        limit_conn emby_bad_conn 1;
        limit_req_status 444;
        limit_conn_status 444;
        return 444;
    }
}
EOF
}
restore_config() {
    local backup="$1" had_old="$2" conf
    conf="$(path "$CONF_FILE")"
    if [[ "$had_old" == "1" ]]; then
        cp "$backup" "$conf" || true
    else
        rm -f "$conf" || true
    fi
}
reload_nginx() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable nginx >/dev/null 2>&1 || true
        if systemctl is-active --quiet nginx; then
            systemctl reload nginx >/dev/null 2>&1
        else
            systemctl start nginx >/dev/null 2>&1
        fi
    else
        service nginx reload >/dev/null 2>&1 || service nginx start >/dev/null 2>&1
    fi
}
config_is_included() {
    nginx_dump | grep -qF "Managed by Provider ngnix.sh"
}
apply_nginx_config() {
    local conf tmp backup had_old=0 fallback=0
    conf="$(path "$CONF_FILE")"
    tmp="$(mktemp /tmp/ngnix-conf.XXXXXX)" || fail "Failed to create nginx temp config"
    backup="$(mktemp /tmp/ngnix-conf-backup.XXXXXX)" || fail "Failed to create nginx backup"
    mkdir -p "$(dirname "$conf")" || fail "Failed to create nginx conf directory"
    if [[ -f "$conf" ]]; then
        had_old=1
        cp "$conf" "$backup" || fail "Failed to backup nginx config"
    fi
    render_nginx_conf "$tmp" 1
    install -m 0644 "$tmp" "$conf" || fail "Failed to write nginx config"
    if ! nginx_test; then
        render_nginx_conf "$tmp" 0
        install -m 0644 "$tmp" "$conf" || fail "Failed to write fallback nginx config"
        nginx_test || {
            restore_config "$backup" "$had_old"
            rm -f "$tmp" "$backup"
            nginx -t || true
            fail "nginx config test failed, rolled back"
        }
        fallback=1
    fi
    config_is_included || {
        restore_config "$backup" "$had_old"
        rm -f "$tmp" "$backup"
        fail "nginx conf.d is not included by current nginx config"
    }
    reload_nginx || {
        restore_config "$backup" "$had_old"
        nginx_test && reload_nginx >/dev/null 2>&1 || true
        rm -f "$tmp" "$backup"
        fail "nginx reload/start failed, rolled back"
    }
    rm -f "$tmp" "$backup"
    [[ "$fallback" == "1" ]] && log "WARN" "ssl_reject_handshake unavailable; using 444 fallback"
    log "OK" "nginx config applied"
}
main() {
    trap cleanup_policy_rc_guard EXIT
    parse_args "$@"
    validate_args
    require_root
    ensure_nginx
    ensure_no_http_listener
    ensure_443_available
    ensure_no_unknown_default_443
    ensure_cert
    apply_nginx_config
    log "OK" "ready: https://${DOMAIN}/${SECRET_PATH}/web/index.html"
}
main "$@"
