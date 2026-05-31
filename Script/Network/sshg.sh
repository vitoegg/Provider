#!/bin/bash

set -o pipefail

ROOT="${SSHG_ROOT:-/}"
NFT_TABLE="sshg"
PROVIDERDNS_BIN="${PROVIDERDNS_BIN:-/usr/local/sbin/providerdns.sh}"
PROVIDERDNS_LOCAL_NAME="providerdns.sh"
PROVIDERDNS_DOWNLOAD_URL="https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/providerdns.sh"
PROVIDERDNS_REQUIRED_API="1"
SSHG_LOCK_HELD=0

log() { printf '[sshg] %s\n' "$*"; }
fail() { printf '[sshg] FAIL %s\n' "$*" >&2; exit 1; }

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
    [ "$(id -u)" = "0" ] || fail "need root"
}

acquire_lock() {
    local lock
    [ "$SSHG_LOCK_HELD" = "1" ] && return 0
    lock="$(sshg_lock_file)"
    mkdir -p "$(dirname "$lock")" || fail "lock dir"
    exec 9>"$lock" || fail "lock"
    if command -v flock >/dev/null 2>&1; then
        flock -n 9 || fail "locked"
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
state_dir() { path "/etc/provider/sshg"; }
allow_file() { path "/etc/provider/sshg/allow.list"; }
nft_file() { path "/etc/nftables.d/sshg.nft"; }
nft_main_file() { path "/etc/nftables.conf"; }
providerdns_subscription_dir() { path "/etc/provider/dns/subscriptions"; }
providerdns_hook_dir() { path "/etc/provider/dns/hooks"; }
providerdns_cache_file() { path "/var/lib/provider/dns/cache.tsv"; }
sshg_dns_subscription() { path "/etc/provider/dns/subscriptions/sshg.list"; }
sshg_dns_hook() { path "/etc/provider/dns/hooks/sshg"; }
sshg_lock_file() { path "/run/sshg.lock"; }

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

classify_allow() {
    local value="$1"
    if validate_cidr "$value"; then
        printf 'cidr %s\n' "$value"
    elif validate_domain "$value"; then
        printf 'domain %s\n' "$value"
    else
        return 1
    fi
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
    public_key_valid "$key" || fail "key invalid"
    file="$(key_file)"
    tmp="${file}.tmp.$$"
    mkdir -p "$(dirname "$file")" || fail "key dir"
    chmod 700 "$(dirname "$file")" 2>/dev/null || true
    printf '%s\n' "$key" > "$tmp" || fail "key write"
    chmod 600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$file" || fail "key install"
    log "key: written"
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
    sshd_has_dropin_include || fail "ssh include"
    sshd="$(sshd_cmd)" || fail "sshd missing"
    ensure_sshd_runtime
    file="$(sshd_dropin)"
    tmp="${file}.tmp.$$"
    backup="${file}.bak.$$"
    mkdir -p "$(dirname "$file")" || fail "ssh dir"
    cat > "$tmp" << 'EOF' || fail "ssh write"
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
MaxAuthTries 3
MaxStartups 10:30:60
AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2 .ssh/authorized_keys3
EOF
    if [ -f "$file" ]; then
        cp "$file" "$backup" || fail "ssh backup"
        had_old=1
    fi
    mv "$tmp" "$file" || fail "ssh install"
    if ! "$sshd" -t >/dev/null 2>&1; then
        if [ "$had_old" = "1" ]; then
            mv "$backup" "$file" 2>/dev/null || true
        else
            rm -f "$file"
        fi
        fail "ssh check"
    fi
    if ! sshd_effective_config_ok "$sshd"; then
        if [ "$had_old" = "1" ]; then
            mv "$backup" "$file" 2>/dev/null || true
        else
            rm -f "$file"
        fi
        fail "ssh effective"
    fi
    rm -f "$backup"
    log "ssh: applied"
}

reload_ssh() {
    local systemctl unit
    [ "$ROOT" != "/" ] && return 0
    systemctl="$(systemctl_cmd 2>/dev/null || true)"
    if [ -n "$systemctl" ]; then
        for unit in ssh.service sshd.service; do
            "$systemctl" is-active --quiet "$unit" >/dev/null 2>&1 || continue
            "$systemctl" reload "$unit" >/dev/null 2>&1 && { log "ssh: reloaded"; return 0; }
        done
        "$systemctl" reload ssh.service >/dev/null 2>&1 && { log "ssh: reloaded"; return 0; }
        "$systemctl" reload sshd.service >/dev/null 2>&1 && { log "ssh: reloaded"; return 0; }
    fi
    if command -v service >/dev/null 2>&1; then
        service ssh reload >/dev/null 2>&1 && { log "ssh: reloaded"; return 0; }
        service sshd reload >/dev/null 2>&1 && { log "ssh: reloaded"; return 0; }
    fi
    pkill -HUP -x sshd >/dev/null 2>&1 && { log "ssh: reloaded"; return 0; }
    fail "ssh reload"
}

append_allow_values() {
    local values="$1" value
    printf '%s' "$values" | tr ',' '\n' | while IFS= read -r value || [ -n "$value" ]; do
        value="$(trim "$value")"
        [ -n "$value" ] || continue
        classify_allow "$value" || fail "allow invalid: $value"
    done
}

write_allow_state() {
    local mode="$1" values="$2" file tmp cidr_count domain_count
    file="$(allow_file)"
    tmp="${file}.tmp.$$"
    mkdir -p "$(dirname "$file")" || fail "state dir"
    : > "$tmp" || fail "state write"
    if [ "$mode" = "apply" ] && [ -s "$file" ]; then
        cat "$file" >> "$tmp"
    fi
    if [ -n "$values" ]; then
        append_allow_values "$values" >> "$tmp" || { rm -f "$tmp"; exit 1; }
    fi
    sort -u "$tmp" -o "$tmp"
    [ -s "$tmp" ] || { rm -f "$tmp"; fail "allow empty"; }
    mv "$tmp" "$file" || fail "state install"
    cidr_count="$(awk '$1=="cidr"{c++} END{print c+0}' "$file")"
    domain_count="$(awk '$1=="domain"{c++} END{print c+0}' "$file")"
    log "allow: updated | cidr=${cidr_count} domain=${domain_count}"
}

providerdns_cache_field() {
    local domain="$1" field="$2" file
    file="$(providerdns_cache_file)"
    [ -s "$file" ] || return 1
    awk -v d="$domain" -v f="$field" '$1==d { print $f; found=1; exit } END { exit(found ? 0 : 1) }' "$file"
}

providerdns_cache_ip() {
    local ip
    ip="$(providerdns_cache_field "$1" 2 2>/dev/null || true)"
    validate_ipv4 "$ip" || return 1
    printf '%s\n' "$ip"
}

run_providerdns() {
    PROVIDERDNS_ROOT="$ROOT" /bin/bash "$PROVIDERDNS_BIN" "$@"
}

providerdns_api_ok() {
    local bin="$1" api
    [ -f "$bin" ] || return 1
    api=$(PROVIDERDNS_ROOT="$ROOT" /bin/bash "$bin" --api 2>/dev/null || true)
    [ "$api" = "$PROVIDERDNS_REQUIRED_API" ]
}

providerdns_is_managed() {
    [ -f "$1" ] && grep -q 'PROVIDERDNS_MANAGED=1' "$1" 2>/dev/null
}

providerdns_local_source() {
    local script_dir local_path
    script_dir="$(cd "$(dirname "$(script_path)")" 2>/dev/null && pwd)"
    local_path="${script_dir}/${PROVIDERDNS_LOCAL_NAME}"
    [ -f "$local_path" ] || return 1
    printf '%s\n' "$local_path"
}

install_providerdns_from_file() {
    local source_file="$1" tmp target_dir
    /bin/bash -n "$source_file" || fail "providerdns syntax"
    providerdns_api_ok "$source_file" || fail "providerdns api"
    if [ "$source_file" = "$PROVIDERDNS_BIN" ]; then
        chmod 755 "$PROVIDERDNS_BIN" 2>/dev/null || true
        return 0
    fi
    target_dir="$(dirname "$PROVIDERDNS_BIN")"
    mkdir -p "$target_dir" || fail "providerdns dir"
    tmp="${PROVIDERDNS_BIN}.tmp.$$"
    cp "$source_file" "$tmp" || { rm -f "$tmp"; fail "providerdns copy"; }
    chmod 755 "$tmp" 2>/dev/null || true
    providerdns_api_ok "$tmp" || { rm -f "$tmp"; fail "providerdns api"; }
    mv "$tmp" "$PROVIDERDNS_BIN" || { rm -f "$tmp"; fail "providerdns install"; }
}

download_providerdns_to() {
    local output="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$PROVIDERDNS_DOWNLOAD_URL" -o "$output"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$output" "$PROVIDERDNS_DOWNLOAD_URL"
    else
        return 1
    fi
}

install_providerdns_from_available_source() {
    local local_source tmp rc
    if local_source="$(providerdns_local_source)"; then
        install_providerdns_from_file "$local_source"
        return $?
    fi
    tmp="$(mktemp /tmp/providerdns.XXXXXX)" || fail "providerdns temp"
    download_providerdns_to "$tmp" || { rm -f "$tmp"; fail "providerdns download"; }
    install_providerdns_from_file "$tmp"
    rc=$?
    rm -f "$tmp"
    return "$rc"
}

ensure_providerdns() {
    if [ -f "$PROVIDERDNS_BIN" ]; then
        if providerdns_api_ok "$PROVIDERDNS_BIN"; then
            chmod 755 "$PROVIDERDNS_BIN" 2>/dev/null || true
            return 0
        fi
        providerdns_is_managed "$PROVIDERDNS_BIN" || fail "providerdns incompatible"
    fi
    install_providerdns_from_available_source
}

providerdns_install() {
    ensure_providerdns
    run_providerdns --install
}

providerdns_refresh() {
    ensure_providerdns
    run_providerdns --refresh
}

build_sources_file() {
    local output="$1" allow type value ip
    allow="$(allow_file)"
    [ -s "$allow" ] || fail "allow empty"
    : > "$output" || fail "source write"
    while read -r type value; do
        case "$type" in
            cidr)
                printf '%s\n' "$value" >> "$output"
                ;;
            domain)
                ip="$(providerdns_cache_ip "$value" || true)"
                validate_ipv4 "$ip" && ipv4_to_24_cidr "$ip" >> "$output"
                ;;
        esac
    done < "$allow"
    sort -u "$output" -o "$output"
    [ -s "$output" ] || fail "source empty"
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
    cat > "$output" << EOF || fail "nft render"
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
    cat >> "$output" << EOF || fail "nft render"

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
    mkdir -p "$(dirname "$config")" || fail "nft dir"
    touch "$config" || fail "nft config"
    grep -Eq '^[[:space:]]*include[[:space:]]+"?/etc/nftables\.d/\*\.nft"?[[:space:]]*$' "$config" && return 0
    printf '\ninclude "/etc/nftables.d/*.nft"\n' >> "$config" || fail "nft include"
}

ensure_nft_service() {
    local systemctl
    [ "$ROOT" != "/" ] && [ -z "${SSHG_SYSTEMCTL:-}" ] && return 0
    systemctl="$(systemctl_cmd 2>/dev/null || true)"
    [ -n "$systemctl" ] || return 0
    "$systemctl" enable nftables.service >/dev/null 2>&1 || log "nft: service skipped"
}

nft_live_ready() {
    local nft="$1"
    "$nft" list table inet "$NFT_TABLE" >/dev/null 2>&1
}

apply_nft() {
    local nft file tmp sources ports source_count
    nft="$(nft_cmd)" || fail "nft missing"
    file="$(nft_file)"
    mkdir -p "$(dirname "$file")" || fail "nft dir"
    tmp="${file}.tmp.$$"
    sources="${file}.sources.$$"
    build_sources_file "$sources"
    ports="$(detect_ssh_ports)" || fail "ssh port"
    render_nft "$sources" "$tmp" "$ports"
    "$nft" -c -f "$tmp" >/dev/null 2>&1 || { rm -f "$tmp" "$sources"; fail "nft check"; }
    ensure_nft_include
    ensure_nft_service
    source_count="$(wc -l < "$sources" | tr -d ' ')"
    if cmp -s "$tmp" "$file" 2>/dev/null && nft_live_ready "$nft"; then
        rm -f "$tmp" "$sources"
        log "nft: skipped | ports=${ports} sources=${source_count}"
        return 0
    fi
    mv "$tmp" "$file" || { rm -f "$sources"; fail "nft install"; }
    chmod 600 "$file" 2>/dev/null || true
    "$nft" -f "$file" >/dev/null 2>&1 || { rm -f "$sources"; fail "nft apply"; }
    rm -f "$sources"
    log "nft: applied | ports=${ports} sources=${source_count}"
}

script_path() {
    local resolved
    resolved="$(command -v readlink >/dev/null 2>&1 && readlink -f "$0" 2>/dev/null || true)"
    [ -n "$resolved" ] || resolved="$0"
    printf '%s\n' "$resolved"
}

allow_has_domain() {
    [ -s "$(allow_file)" ] && awk '$1=="domain"{found=1} END{exit(found ? 0 : 1)}' "$(allow_file)"
}

providerdns_cleanup_if_unused() {
    [ -f "$PROVIDERDNS_BIN" ] || return 0
    providerdns_api_ok "$PROVIDERDNS_BIN" || return 0
    run_providerdns --cleanup unused
}

write_sshg_dns_subscription() {
    local tmp
    mkdir -p "$(providerdns_subscription_dir)" "$(providerdns_hook_dir)" || fail "dns dir"
    tmp="$(sshg_dns_subscription).tmp.$$"
    awk '$1=="domain"{print $2}' "$(allow_file)" | sort -u > "$tmp" || { rm -f "$tmp"; fail "dns write"; }
    if [ -s "$tmp" ]; then
        mv "$tmp" "$(sshg_dns_subscription)" || fail "dns install"
        chmod 644 "$(sshg_dns_subscription)" 2>/dev/null || true
    else
        rm -f "$tmp" "$(sshg_dns_subscription)"
    fi
}

write_sshg_dns_hook() {
    local script
    script="$(script_path)"
    mkdir -p "$(providerdns_hook_dir)" || fail "dns dir"
    cat > "$(sshg_dns_hook)" << EOF || fail "hook write"
#!/bin/bash
/bin/bash "${script}" --apply cache
EOF
    chmod 755 "$(sshg_dns_hook)" || fail "hook mode"
}

reconcile_sshg_dns() {
    if allow_has_domain; then
        write_sshg_dns_subscription
        write_sshg_dns_hook
        providerdns_install
        providerdns_refresh
    else
        rm -f "$(sshg_dns_subscription)" "$(sshg_dns_hook)"
        providerdns_cleanup_if_unused
    fi
}

sync_rules() {
    reconcile_sshg_dns
    apply_nft
}

apply_cache_rules() {
    [ -s "$(allow_file)" ] || fail "allow empty"
    apply_nft
}

remove_active_nft() {
    local nft tmp
    nft="$(nft_cmd 2>/dev/null || true)"
    [ -n "$nft" ] || return 0
    tmp="$(mktemp /tmp/sshg-clean.XXXXXX)" || return 0
    cat > "$tmp" << EOF
table inet ${NFT_TABLE}
delete table inet ${NFT_TABLE}
EOF
    "$nft" -f "$tmp" >/dev/null 2>&1 || true
    rm -f "$tmp"
}

remove_all() {
    local systemctl
    [ "$ROOT" = "/" ] && systemctl="$(systemctl_cmd 2>/dev/null || true)" || systemctl=""
    remove_active_nft
    rm -f "$(sshd_dropin)" "$(key_file)" "$(nft_file)" "$(sshg_dns_subscription)" "$(sshg_dns_hook)"
    rm -rf "$(state_dir)"
    providerdns_cleanup_if_unused
    [ -z "$systemctl" ] || "$systemctl" daemon-reload >/dev/null 2>&1 || true
    reload_ssh
    log "remove: done"
}

show_help() {
    cat << 'EOF'
Usage:
  sshg.sh --apply allow=1.2.3.4,1.2.3.0/24,example.com key='ssh-ed25519 AAAA...'
  sshg.sh --reset allow=1.2.3.4,example.com key='ssh-ed25519 AAAA...'
  sshg.sh --sync
  sshg.sh --apply cache
  sshg.sh --remove

Actions:
  --apply        merge allow list, write ssh config, refresh nft
  --reset        replace allow list, write ssh config, refresh nft
  --sync         resolve domains and refresh nft
  --apply cache  apply shared DNS cache to nft
  --remove       remove sshg files and nft table
EOF
}

main() {
    local action="${1:-}" mode="" allow_values="" key_value="" arg
    case "$action" in
        --apply|apply)
            shift
            if [ "${1:-}" = "cache" ]; then
                mode="cache"
                shift
            else
                mode="state"
            fi
            ;;
        --reset|reset) mode="state"; shift ;;
        --sync|sync) shift ;;
        --remove|remove) shift ;;
        dns) shift ;;
        help|-h|--help|"") show_help; [ -n "$action" ]; exit $? ;;
        *) fail "action unknown" ;;
    esac

    while [ "$#" -gt 0 ]; do
        arg="$1"
        case "$arg" in
            allow=*)
                allow_values="${allow_values}${allow_values:+,}${arg#allow=}"
                ;;
            key=*)
                key_value="${arg#key=}"
                ;;
            *)
                fail "arg unknown: $arg"
                ;;
        esac
        shift
    done

    require_root
    case "$action" in
        --apply|apply|--reset|reset|--sync|sync|--remove|remove) acquire_lock ;;
    esac
    case "$action" in
        --apply|apply)
            if [ "$mode" = "cache" ]; then
                apply_cache_rules
                exit 0
            fi
            [ -z "$key_value" ] || public_key_valid "$(trim "$key_value")" || fail "key invalid"
            [ -n "$key_value" ] || root_key_exists || fail "root key missing"
            write_allow_state "apply" "$allow_values"
            write_ssh_config
            write_key "$key_value"
            sync_rules
            reload_ssh
            ;;
        --reset|reset)
            [ -z "$key_value" ] || public_key_valid "$(trim "$key_value")" || fail "key invalid"
            [ -n "$key_value" ] || root_key_exists || fail "root key missing"
            write_allow_state "reset" "$allow_values"
            write_ssh_config
            write_key "$key_value"
            sync_rules
            reload_ssh
            ;;
        --sync|sync)
            [ -s "$(allow_file)" ] || fail "allow empty"
            sync_rules
            ;;
        dns)
            ensure_providerdns
            run_providerdns --refresh hooks
            ;;
        --remove|remove)
            remove_all
            ;;
    esac
}

main "$@"
