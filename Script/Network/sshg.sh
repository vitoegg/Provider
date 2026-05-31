#!/bin/bash

set -o pipefail

ROOT="${SSHG_ROOT:-/}"
NFT_TABLE="sshg"
PROVIDERDNS_BIN="${PROVIDERDNS_BIN:-/usr/local/sbin/providerdns.sh}"
PROVIDERDNS_LOCAL_NAME="providerdns.sh"
PROVIDERDNS_CONSUMER="sshg"
SSHG_LOCK_HELD=0
SSHG_ALLOW_DROPPED=0
SSHG_DNS_ROLLBACK_ON_FAIL=0

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

remove_key() {
    rm -f "$(key_file)" || fail "key remove"
    log "key: removed"
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

root_key_exists_without_managed() {
    local file line value
    for file in "$(path "/root/.ssh/authorized_keys")" "$(path "/root/.ssh/authorized_keys2")"; do
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

remove_ssh_config() {
    rm -f "$(sshd_dropin)" || fail "ssh remove"
    log "ssh: removed"
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

build_allow_candidate() {
    local mode="$1" values="$2" output="$3"
    : > "$output" || fail "state write"
    if [ "$mode" = "apply" ] && [ -s "$(allow_file)" ]; then
        cat "$(allow_file)" >> "$output"
    fi
    if [ -n "$values" ]; then
        append_allow_values "$values" >> "$output" || { rm -f "$output"; exit 1; }
    fi
    sort -u "$output" -o "$output"
    [ -s "$output" ] || fail "allow empty"
}

log_allow_state() {
    local file cidr_count domain_count
    file="$(allow_file)"
    cidr_count="$(awk '$1=="cidr"{c++} END{print c+0}' "$file")"
    domain_count="$(awk '$1=="domain"{c++} END{print c+0}' "$file")"
    log "allow: updated | cidr=${cidr_count} domain=${domain_count}"
}

providerdns_cache_field() {
    local domain="$1" field="$2" record
    record="$(run_providerdns --cache "$domain" 2>/dev/null)" || return 1
    awk -v f="$field" '{ print $f }' <<< "$record"
}

providerdns_cache_ip() {
    local ip
    ip="$(providerdns_cache_field "$1" 2 2>/dev/null || true)"
    validate_ipv4 "$ip" || return 1
    printf '%s\n' "$ip"
}

run_providerdns() {
    local bin
    bin="$(providerdns_bin)" || return 1
    PROVIDERDNS_ROOT="$ROOT" /bin/bash "$bin" "$@"
}

providerdns_local_source() {
    local script_dir local_path
    script_dir="$(cd "$(dirname "$(script_path)")" 2>/dev/null && pwd)"
    local_path="${script_dir}/${PROVIDERDNS_LOCAL_NAME}"
    [ -f "$local_path" ] || return 1
    printf '%s\n' "$local_path"
}

providerdns_bin() {
    local bin="${PROVIDERDNS_BIN:-/usr/local/sbin/providerdns.sh}" local_source
    [ -f "$bin" ] && { printf '%s\n' "$bin"; return 0; }
    if local_source="$(providerdns_local_source)"; then
        printf '%s\n' "$local_source"
        return 0
    fi
    return 1
}

find_providerdns() {
    providerdns_bin >/dev/null
}

require_providerdns() {
    find_providerdns && return 0
    fail "need providerdns.sh: set PROVIDERDNS_BIN, or place providerdns.sh at /usr/local/sbin/providerdns.sh, or place it next to sshg.sh"
}

providerdns_refresh() {
    require_providerdns
    run_providerdns --refresh
}

providerdns_set_sshg() {
    local domains_file="$1" script quoted_script hook_command
    require_providerdns
    script="$(script_path)"
    printf -v quoted_script '%q' "$script"
    hook_command="/bin/bash ${quoted_script} --apply cache"
    run_providerdns --set "$PROVIDERDNS_CONSUMER" "$domains_file" "$hook_command"
}

providerdns_unset_sshg() {
    find_providerdns || return 0
    run_providerdns --unset "$PROVIDERDNS_CONSUMER"
}

allow_has_domain_file() {
    [ -s "$1" ] && awk '$1=="domain"{found=1} END{exit(found ? 0 : 1)}' "$1"
}

write_allow_domains() {
    local allow="$1" output="$2"
    awk '$1=="domain"{print $2}' "$allow" | sort -u > "$output"
}

set_providerdns_for_allow() {
    local allow="$1" domains_file
    if allow_has_domain_file "$allow"; then
        domains_file="$(mktemp /tmp/sshg-domains.XXXXXX)" || fail "dns temp"
        write_allow_domains "$allow" "$domains_file" || { rm -f "$domains_file"; fail "dns write"; }
        providerdns_set_sshg "$domains_file"
        rm -f "$domains_file"
    else
        providerdns_unset_sshg
    fi
}

refresh_providerdns_for_allow() {
    allow_has_domain_file "$1" || { providerdns_unset_sshg; return 0; }
    set_providerdns_for_allow "$1"
    providerdns_refresh
}

filter_allow_domains() {
    local allow="$1" tmp type value ip
    SSHG_ALLOW_DROPPED=0
    allow_has_domain_file "$allow" || return 0
    tmp="${allow}.filtered.$$"
    : > "$tmp" || fail "allow filter"
    while read -r type value; do
        case "$type" in
            cidr)
                printf '%s %s\n' "$type" "$value" >> "$tmp"
                ;;
            domain)
                ip="$(providerdns_cache_ip "$value" || true)"
                if validate_ipv4 "$ip"; then
                    printf '%s %s\n' "$type" "$value" >> "$tmp"
                else
                    SSHG_ALLOW_DROPPED=$((SSHG_ALLOW_DROPPED + 1))
                    log "warn: domain unresolved, skipped from allow state: $value"
                fi
                ;;
        esac
    done < "$allow"
    sort -u "$tmp" -o "$tmp"
    mv "$tmp" "$allow" || { rm -f "$tmp"; fail "allow filter"; }
    [ "$SSHG_ALLOW_DROPPED" -eq 0 ] || set_providerdns_for_allow "$allow"
}

build_sources_file() {
    local output="$1" allow="${2:-$(allow_file)}" type value ip
    [ -s "$allow" ] || fail "allow empty"
    : > "$output" || fail "source write"
    while read -r type value; do
        case "$type" in
            cidr)
                printf '%s\n' "$value" >> "$output"
                ;;
            domain)
                ip="$(providerdns_cache_ip "$value" || true)"
                if validate_ipv4 "$ip"; then
                    ipv4_to_24_cidr "$ip" >> "$output"
                else
                    log "warn: domain unresolved, skipped from nft allow set: $value"
                fi
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
    mkdir -p "$(dirname "$config")" || return 1
    touch "$config" || return 1
    grep -Eq '^[[:space:]]*include[[:space:]]+"?/etc/nftables\.d/\*\.nft"?[[:space:]]*$' "$config" && return 0
    printf '\ninclude "/etc/nftables.d/*.nft"\n' >> "$config" || return 1
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

rollback_file() {
    local target="$1" backup="$2" had_backup="$3"
    if [ "$had_backup" = "1" ]; then
        mv "$backup" "$target" 2>/dev/null || true
    else
        rm -f "$target" 2>/dev/null || true
    fi
}

rollback_dns_if_needed() {
    [ "$SSHG_DNS_ROLLBACK_ON_FAIL" = "1" ] || return 0
    SSHG_DNS_ROLLBACK_ON_FAIL=0
    reconcile_sshg_dns >/dev/null 2>&1 || true
}

fail_transaction() {
    rollback_dns_if_needed
    fail "$1"
}

apply_nft() {
    apply_nft_from_allow "$(allow_file)" "0"
}

apply_nft_from_allow() {
    local allow="$1" commit_allow="${2:-0}"
    local nft file tmp sources ports source_count allow_path allow_tmp allow_backup nft_backup had_allow=0 had_nft=0
    nft="$(nft_cmd)" || fail_transaction "nft missing"
    file="$(nft_file)"
    allow_path="$(allow_file)"
    mkdir -p "$(dirname "$file")" || fail_transaction "nft dir"
    tmp="${file}.tmp.$$"
    sources="${file}.sources.$$"
    build_sources_file "$sources" "$allow"
    ports="$(detect_ssh_ports)" || fail_transaction "ssh port"
    render_nft "$sources" "$tmp" "$ports"
    "$nft" -c -f "$tmp" >/dev/null 2>&1 || { rm -f "$tmp" "$sources"; fail_transaction "nft check"; }
    ensure_nft_include || fail_transaction "nft include"
    ensure_nft_service
    source_count="$(wc -l < "$sources" | tr -d ' ')"
    if [ "$commit_allow" = "0" ] && cmp -s "$tmp" "$file" 2>/dev/null && nft_live_ready "$nft"; then
        rm -f "$tmp" "$sources"
        log "nft: skipped | ports=${ports} sources=${source_count}"
        return 0
    fi
    if [ "$commit_allow" = "1" ]; then
        mkdir -p "$(dirname "$allow_path")" || fail_transaction "state dir"
        allow_tmp="${allow_path}.tmp.$$"
        allow_backup="${allow_path}.bak.$$"
        [ ! -f "$allow_path" ] || { cp "$allow_path" "$allow_backup" || fail_transaction "state backup"; had_allow=1; }
        cp "$allow" "$allow_tmp" || { rm -f "$allow_backup"; fail_transaction "state write"; }
        mv "$allow_tmp" "$allow_path" || { rm -f "$allow_tmp" "$allow_backup"; fail_transaction "state install"; }
    fi
    nft_backup="${file}.bak.$$"
    [ ! -f "$file" ] || { cp "$file" "$nft_backup" || { [ "$commit_allow" = "0" ] || rollback_file "$allow_path" "$allow_backup" "$had_allow"; fail_transaction "nft backup"; }; had_nft=1; }
    if ! mv "$tmp" "$file"; then
        [ "$commit_allow" = "0" ] || rollback_file "$allow_path" "$allow_backup" "$had_allow"
        rm -f "$sources" "$nft_backup"
        fail_transaction "nft install"
    fi
    chmod 600 "$file" 2>/dev/null || true
    if ! "$nft" -f "$file" >/dev/null 2>&1; then
        rollback_file "$file" "$nft_backup" "$had_nft"
        [ "$commit_allow" = "0" ] || rollback_file "$allow_path" "$allow_backup" "$had_allow"
        rm -f "$sources"
        fail_transaction "nft apply"
    fi
    rm -f "$sources" "$nft_backup" "$allow_backup"
    [ "$commit_allow" = "0" ] || log_allow_state
    log "nft: applied | ports=${ports} sources=${source_count}"
}

script_path() {
    local resolved
    resolved="$(command -v readlink >/dev/null 2>&1 && readlink -f "$0" 2>/dev/null || true)"
    [ -n "$resolved" ] || resolved="$0"
    printf '%s\n' "$resolved"
}

allow_has_domain() {
    allow_has_domain_file "$(allow_file)"
}

reconcile_sshg_dns() {
    refresh_providerdns_for_allow "$(allow_file)"
}

sync_rules_from_candidate() {
    local candidate="$1"
    if allow_has_domain_file "$candidate"; then
        refresh_providerdns_for_allow "$candidate"
        SSHG_DNS_ROLLBACK_ON_FAIL=1
        filter_allow_domains "$candidate"
    fi
    [ -s "$candidate" ] || fail_transaction "allow empty"
    apply_nft_from_allow "$candidate" "1"
    SSHG_DNS_ROLLBACK_ON_FAIL=0
    allow_has_domain_file "$candidate" || set_providerdns_for_allow "$candidate"
}

sync_rules() {
    local candidate
    [ -s "$(allow_file)" ] || fail "allow empty"
    candidate="$(mktemp /tmp/sshg-allow.XXXXXX)" || fail "allow temp"
    cp "$(allow_file)" "$candidate" || { rm -f "$candidate"; fail "allow read"; }
    sync_rules_from_candidate "$candidate"
    rm -f "$candidate"
}

update_allow_state() {
    local mode="$1" values="$2" candidate
    candidate="$(mktemp /tmp/sshg-allow.XXXXXX)" || fail "allow temp"
    build_allow_candidate "$mode" "$values" "$candidate"
    sync_rules_from_candidate "$candidate"
    rm -f "$candidate"
}

apply_cache_rules() {
    [ -s "$(allow_file)" ] || fail "allow empty"
    apply_nft
}

clear_allow_state() {
    remove_active_nft
    rm -f "$(allow_file)" "$(nft_file)"
    rmdir "$(state_dir)" 2>/dev/null || true
    providerdns_unset_sshg
    log "allow: cleared"
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
    rm -f "$(sshd_dropin)" "$(key_file)" "$(nft_file)"
    rm -rf "$(state_dir)"
    providerdns_unset_sshg
    [ -z "$systemctl" ] || "$systemctl" daemon-reload >/dev/null 2>&1 || true
    reload_ssh
    log "remove: done"
}

show_help() {
    cat << 'EOF'
Usage:
  sshg.sh --apply config=ssh allow=1.2.3.4,1.2.3.0/24,example.com key='ssh-ed25519 AAAA...'
  sshg.sh --reset config=ssh allow=1.2.3.4,example.com key='ssh-ed25519 AAAA...'
  sshg.sh --sync
  sshg.sh --apply cache
  sshg.sh --remove

Actions:
  --apply        apply provided config/key/allow changes
  --reset        set target config/key/allow state, missing fields are removed
  --sync         resolve domains and refresh nft
  --apply cache  apply shared DNS cache to nft
  --remove       remove sshg files and nft table

Parameters:
  config=ssh     write ssh hardening config
  key=...        write root authorized_keys3
  allow=...      comma-separated IPv4, IPv4 CIDR, or domain entries
EOF
}

main() {
    local action="${1:-}" mode="" allow_values="" key_value="" config_value="" arg
    local allow_seen=0 key_seen=0 config_seen=0 did_change=0 ssh_reload_needed=0
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
                allow_seen=1
                allow_values="${allow_values}${allow_values:+,}${arg#allow=}"
                ;;
            key=*)
                key_seen=1
                key_value="${arg#key=}"
                ;;
            config=*)
                config_seen=1
                config_value="${arg#config=}"
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
            [ "$config_seen" = "0" ] || [ "$config_value" = "ssh" ] || fail "config invalid"
            [ "$key_seen" = "0" ] || public_key_valid "$(trim "$key_value")" || fail "key invalid"
            if [ "$config_seen" = "1" ] && [ "$key_seen" = "0" ]; then
                root_key_exists || fail "root key missing"
            fi
            if [ "$allow_seen" = "1" ]; then
                update_allow_state "apply" "$allow_values"
                did_change=1
            fi
            if [ "$key_seen" = "1" ]; then
                write_key "$key_value"
                did_change=1
            fi
            if [ "$config_seen" = "1" ]; then
                root_key_exists || fail "root key missing"
                write_ssh_config
                ssh_reload_needed=1
                did_change=1
            fi
            [ "$did_change" = "1" ] || fail "nothing to do"
            [ "$ssh_reload_needed" = "0" ] || reload_ssh
            ;;
        --reset|reset)
            [ "$config_seen" = "0" ] || [ "$config_value" = "ssh" ] || fail "config invalid"
            [ "$key_seen" = "0" ] || public_key_valid "$(trim "$key_value")" || fail "key invalid"
            if [ "$config_seen" = "1" ] && [ "$key_seen" = "0" ]; then
                root_key_exists_without_managed || fail "root key missing"
            fi
            if [ "$allow_seen" = "1" ]; then
                update_allow_state "reset" "$allow_values"
            else
                clear_allow_state
            fi
            if [ "$key_seen" = "1" ]; then
                write_key "$key_value"
            else
                remove_key
            fi
            if [ "$config_seen" = "1" ]; then
                root_key_exists || fail "root key missing"
                write_ssh_config
            else
                remove_ssh_config
            fi
            reload_ssh
            ;;
        --sync|sync)
            [ -s "$(allow_file)" ] || fail "allow empty"
            sync_rules
            ;;
        dns)
            require_providerdns
            run_providerdns --refresh hooks
            ;;
        --remove|remove)
            remove_all
            ;;
    esac
}

main "$@"
