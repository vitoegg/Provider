# Network Scripts

### reality.sh
Install and manage Reality and ShadowSocks services using Xray.
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/reality.sh && bash reality.sh
```
* `--install`: Install service.
* `--update`: Update service.
* `--uninstall`: Uninstall service.
* `--install-type`: Installation type (reality_only, reality_ss).
* `--domain`: Target domain for Reality.
* `--reality-port`: Port for Reality service.
* `--uuid`: UUID for VLESS.
* `--private-key`: Private key for Reality.
* `--public-key`: Public key for Reality.
* `--short-id`: Short ID for Reality.
* `--ss-port`: Port for ShadowSocks.
* `--ss-password`: Password for ShadowSocks.

### shadowtls.sh
Install and manage Shadowsocks and ShadowTLS services.
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/shadowtls.sh && bash shadowtls.sh
```
* `--ss-port`: Shadowsocks server port.
* `--ss-pass`: Shadowsocks password.
* `--tls-port`: ShadowTLS server port.
* `--tls-pass`: ShadowTLS password.
* `--tls-domain`: ShadowTLS domain.

### snell.sh
Install and manage Snell proxy server.
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/snell.sh && bash snell.sh
```
* `-i`: Install Snell server (optional version).
* `-n`: Update Snell server (optional version).
* `-u`: Uninstall Snell server.
* `-p`: Specify listen port.
* `-k`: Specify Pre-Shared Key.

### anytls.sh
Install and manage AnyTLS service using Singbox.
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/anytls.sh && bash anytls.sh
```
**Configuration Options:**
* `--port`: Specify AnyTLS port (default: auto-generated 50000-60000).
* `--password`: Specify AnyTLS password (default: auto-generated).
* `--domain`: Specify domain name.
* `--version`: Specify Singbox version to install.
* `-s, --scheme`: Specify padding scheme (pipe `|` separated values).
  * Default: `stop=3|0=30-30|1=140-320|2=420-780,c,780-1400`

**Certificate Options (mutually exclusive modes):**
* `--cert-mode`: Certificate mode: `acme` (auto-generate) or `manual` (use existing).
* `--token`: [ACME mode] Cloudflare API Token for DNS-01 certificate challenge.
* `--cert-path`: [Manual mode] Path to TLS certificate file.
* `--key-path`: [Manual mode] Path to TLS private key file.

**Management Options:**
* `--update`: Update Singbox to the latest version.
* `--uninstall`: Uninstall Singbox service and remove configuration.

**Examples:**
```bash
# ACME mode: Auto-generate certificate
bash anytls.sh --domain api.example.com --token YOUR_CF_TOKEN

# Manual mode: Use existing certificate
bash anytls.sh --cert-mode manual --domain api.example.com --cert-path /etc/ssl/certs/cert.crt --key-path /etc/ssl/certs/cert.key

# Custom padding scheme
bash anytls.sh --domain api.example.com --token YOUR_CF_TOKEN -s 'stop=5|0=50-50|1=200-400'
```

### shadowsocks.sh
Install and manage Shadowsocks-rust service.
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/shadowsocks.sh && bash shadowsocks.sh
```
* `-s`: Specify Shadowsocks password.
* `-p`: Specify Shadowsocks port.
* `-u`: Uninstall Shadowsocks-rust service and remove related files.

### smartdns.sh
Install and manage SmartDNS service.
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/smartdns.sh && bash smartdns.sh
```
* `-e`: Specify ECS region (HK, TYO, LA, SEA).
* `-u`: Uninstall SmartDNS service.

### mosdns.sh
Install and manage MosDNS service with custom DNS and ECS support.
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/mosdns.sh && bash mosdns.sh
```
* `-i`: Install with default configuration.
* `-d`: Specify custom DNS server address.
* `-e`: Specify ECS location (HK, TYO, LA, SEA).
* `-4`, `--ipv4`: Prefer IPv4 when resolving dual-stack domains (default).
* `-6`, `--ipv6`: Prefer IPv6 when resolving dual-stack domains.
* `-u`: Uninstall MosDNS service.

### sshg.sh
Harden SSH and restrict SSH access by nftables allowlist.
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/sshg.sh && bash sshg.sh --help
```
* `--apply`: Merge new allow entries with current state.
* `--reset`: Replace current allow entries.
* `--sync`: Resolve domain entries and refresh nftables.
* `--remove`: Remove sshg files and nftables table.
* `allow=`: Comma-separated IPv4, IPv4 CIDR, or domain entries.
* `key=`: Optional root public key, written to `/root/.ssh/authorized_keys3`.

Generated files:
* `/etc/ssh/sshd_config.d/00-sshg.conf`
* `/root/.ssh/authorized_keys3`
* `/etc/sshg/allow.ipv4`
* `/etc/sshg/allow.domain`
* `/etc/nftables.d/sshg.nft`
* `/etc/provider/dns/subscriptions/sshg.list`
* `/etc/provider/dns/hooks/sshg`

Examples:
```bash
bash sshg.sh --reset allow=1.2.3.4,1.2.3.0/24,example.com key='ssh-ed25519 AAAA...'
bash sshg.sh --apply allow=5.6.7.8
bash sshg.sh --sync
bash sshg.sh --remove
```

### providerdns.sh
Shared DNS runtime used by `nftables.sh` and `sshg.sh`.
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/providerdns.sh && bash providerdns.sh --help
```
* `--install`: Install or repair `providerdns.service` and `providerdns.timer`.
* `--set <consumer> <domain-file> <hook-command>`: Register a consumer's domain list and cache-change hook.
* `--unset <consumer>`: Remove a consumer registration.
* `--refresh`: Resolve subscribed domains and update cache.
* `--refresh hooks`: Resolve subscribed domains and run affected hooks only when their domains change.
* `--cache <domain>`: Print one cached DNS record.
* `--lookup <domain>`: Print cached or freshly resolved IPv4.
* `--cleanup unused`: Remove Provider DNS runtime when no subscriptions remain.

Provider DNS files:
* `/usr/local/sbin/providerdns.sh`
* `/etc/provider/dns/subscriptions/*.list`
* `/etc/provider/dns/hooks/*`
* `/var/lib/provider/dns/cache.tsv`
* `/etc/systemd/system/providerdns.service`
* `/etc/systemd/system/providerdns.timer`

When `nftables.sh` or `sshg.sh` needs Provider DNS, it uses `PROVIDERDNS_BIN` when that file exists (`/usr/local/sbin/providerdns.sh` by default), otherwise the `providerdns.sh` next to the caller. If none exists, domain-based operations fail before changing state.

### nftables.sh
Manage NFTables port forwarding and firewall protection with declarative state.
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/nftables.sh && bash nftables.sh --help
```
**Rule Format:** `source_port:target(IPv4/domain/local):target_port[:snat_ip[:mss]]`
* Remote forwarding: `8080:192.168.1.10:80`
* Domain forwarding: `8443:example.com:443`
* Local forwarding: `9000:local:3000`
* Private-line forwarding: `10086:82.40.1.2:33333:10.100.1.2`
* Private-line forwarding with automatic MSS clamp: `10086:82.40.1.2:33333:10.100.1.2:auto`
* Private-line forwarding with fixed MSS clamp: `10086:82.40.1.2:33333:10.100.1.2:1360`

**Options:**
* `--help`, `-h`: Show help message.
* `--list`, `-l`: List current forwarding rules.
* `--add`, `-a`: Add forwarding rules (auto-enable protection).
* `--delete`, `-d`: Delete forwarding rules.
* `--replace`, `-r`: Clear existing rules and add new rules.
* `--ddns sync`: Resolve shared DNS subscriptions.
* `--ddns apply`: Apply shared DNS cache to forwarding rules.
* `--ddns list`: List domain forwarding state.
* `--protect on`: Enable port protection.
* `--protect off`: Disable port protection.
* `--protect status`: Show protection status.
* `--protect sync`: Rebuild protection ports from current state.
* `--uninstall`, `-u`: Remove generated rules, state, timers and sysctl configuration.

Domain rules use Provider DNS consumer registration. Unresolved domains are saved as pending, do not render forwarding rules, and do not open protect ports until DNS resolves.

**Examples:**
```bash
# Add forwarding rules
bash nftables.sh --add 21443:1.2.3.4:51080 31443:1.2.3.4:52080

# Add private-line forwarding with explicit SNAT
bash nftables.sh --add 10086:82.40.1.2:33333:10.100.1.2:auto

# Replace all rules
bash nftables.sh --replace 8080:192.168.1.10:80

# Check protection status
bash nftables.sh --protect status

# Sync domain rules
bash nftables.sh --ddns sync
bash nftables.sh --ddns apply

# Uninstall nftables.sh artifacts
bash nftables.sh --uninstall
```

### kernel.sh
Apply a minimal Linux network optimization profile with BBR and fq.
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/kernel.sh && bash kernel.sh
```
Clean old kernel.sh configuration without backup:
```bash
[ -f /etc/sysctl.conf ] && : > /etc/sysctl.conf; [ -f /etc/security/limits.conf ] && : > /etc/security/limits.conf; rm -f /usr/lib/modules-load.d/tls-loader.conf; [ -f /etc/pam.d/common-session ] && sed -i '/^[[:space:]]*session[[:space:]]\+required[[:space:]]\+pam_limits\.so[[:space:]]*$/d' /etc/pam.d/common-session; sysctl --system >/dev/null 2>&1 || true; echo "[OK] old kernel.sh config removed"
```
* `-6`: IPv6 (yes, no).
* `-u`: Remove kernel optimization configuration.
