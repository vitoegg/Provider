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
* `--port`: Specify AnyTLS port (default: auto-generated 50000-60000).
* `--password`: Specify AnyTLS password (default: auto-generated).
* `--domain`: Specify domain name.
* `--version`: Specify Singbox version to install.
* `--update`: Update Singbox to the latest version.
* `--uninstall`: Uninstall Singbox service and remove configuration.

### shadowsocks.sh
Install and manage Shadowsocks-rust service.
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/shadowsocks.sh && bash shadowsocks.sh
```
* `-s`: Specify Shadowsocks password.
* `-p`: Specify Shadowsocks port.

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
* `-u`: Uninstall MosDNS service.

### nftables.sh
Manage NFTables port forwarding rules.
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/nftables.sh && bash nftables.sh
```
* `--add`: Add forwarding rule (Format: "port:ip:port").
* `--remove`: Remove forwarding rule by port.
* `--remove-all`: Remove all forwarding rules.
* `--list`: List current forwarding rules.

### iptables.sh
Manage iptables forwarding rules with an interactive menu.
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/iptables.sh && bash iptables.sh
```

### realm.sh
Manage Realm TCP/UDP forwarding service.
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/realm.sh && bash realm.sh
```
* `--add`: Add forwarding rule (Format: "port:address:port").
* `--remove`: Remove forwarding rule by port.
* `--remove-all`: Remove all forwarding rules.
* `--list`: List current forwarding rules.
* `--status`: Show service status.
* `--uninstall`: Uninstall Realm service.

### kernel.sh
Optimize Linux kernel network parameters for better performance.
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/kernel.sh && bash kernel.sh
```
* `-r`: Region configuration (jp, hk, us, custom).
* `-q`: Queue discipline (fq, fq_pie, cake).
* `-d`: Disable IPv6 (yes, no).

### ssh_keys.sh
Configure SSH public key authentication.
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/ssh_keys.sh && bash ssh_keys.sh
```
* `-k`: SSH public key string (required).

### tcp.sh
Configure and optimize TCP network settings.
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/tcp.sh && bash tcp.sh
```

### traffic.sh
Monitor and limit network traffic usage.
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/traffic.sh && bash traffic.sh
```
* `$1`: Traffic limit in GB.
* `$2`: Day of the month to reset traffic.
* `$3`: Traffic check mode (1: Upload, 2: Download, 3: Max(Up, Down), 4: Total).
* `$4`: Network interface name.

### ipconfig.sh
Configure IP priority (IPv4/IPv6) for the system.
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/ipconfig.sh && bash ipconfig.sh
```
* `-v4`: Set IPv4 priority.
* `-v6`: Set IPv6 priority.
* `-u`: Restore default settings.