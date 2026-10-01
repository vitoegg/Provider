# Network Scripts

## **singbox.sh**

### 下载
```bash
curl -fSLO https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/singbox.sh
```

### 参数说明
```text
--protocol LIST                 anytls、shadowsocks、shadowtls、trojan，支持逗号组合
--shadowtls-port PORT           ShadowTLS 端口
--shadowtls-password PASSWORD   ShadowTLS 密码
--shadowtls-domain DOMAIN       ShadowTLS 单域名，启用时自动配置 Shadowsocks
--anytls-port PORT              AnyTLS 端口
--anytls-password PASS          AnyTLS 密码
--anytls-domain DOMAIN          AnyTLS 域名
--anytls-scheme SCHEME          AnyTLS padding scheme
--anytls-cert-mode acme|manual  AnyTLS 证书模式
--anytls-token TOKEN            Cloudflare API Token
--anytls-cert-path PATH         证书路径
--anytls-key-path PATH          私钥路径
--trojan-port PORT              Trojan 端口
--trojan-password PASSWORD      Trojan 密码
--trojan-domain DOMAIN          Trojan 域名
--trojan-cert-path PATH         证书路径
--trojan-key-path PATH          私钥路径
--trojan-ws-name NAME           Trojan WS 单段路径名
--ss-port PORT                  Shadowsocks 端口
--ss-password PASSWORD          Shadowsocks 密码
--socks-host HOST               Socks 服务 IP
--socks-port PORT               Socks 服务端口
--version VERSION               sing-box 版本
--update                        更新 sing-box
-u, --uninstall                 卸载 sing-box
-h, --help                      显示帮助
```

安装时必须提供 `--protocol`；无参数会直接报错。未提供端口或密码时沿用现有配置中的值，没有则自动生成。

### 示例命令
```bash
bash singbox.sh \
  --protocol shadowtls \
  --shadowtls-domain www.example.com

bash singbox.sh \
  --protocol anytls,shadowsocks \
  --anytls-domain api.example.com \
  --anytls-token YOUR_CF_TOKEN \
  --socks-host 1.2.3.4 \
  --socks-port 1080

bash singbox.sh \
  --protocol trojan \
  --trojan-domain stream.example.com \
  --trojan-port 443 \
  --trojan-cert-path /path/to/cert.pem \
  --trojan-key-path /path/to/key.pem \
  --trojan-ws-name jpg
```

## **shadowsocks.sh**

### 下载
```bash
curl -fSLO https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/shadowsocks.sh
```

### 参数说明
```text
-s password             Shadowsocks 密码，16 字节密钥的 base64 编码
-p port                 Shadowsocks 端口
--update                更新 Shadowsocks
-u                      卸载
-h, --help              显示帮助
```

无参数时安装或修复 Shadowsocks。未提供端口或密码时沿用现有配置中的值，没有则自动生成。

### 示例命令
```bash
bash shadowsocks.sh -s "$(openssl rand -base64 16)" -p 25252
```

## **socks.sh**

### 下载
```bash
curl -fSLO https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/socks.sh
```

### 参数说明
```text
--port PORT                 监听端口，未提供时沿用现有配置，没有则自动生成
--allow-ip IP[,IP...]       Dante 允许的客户端 IPv4，必填且可重复使用
-u, --uninstall             卸载 Dante
-h, --help                  显示帮助
```

安装时 `--allow-ip` 必填；无参数会直接报错。端口准入由 `nftables.sh` 统一负责，白名单模式下需要将这些 IP 同时加入 `--whitelist`。

### 示例命令
```bash
bash socks.sh --port 28080 --allow-ip 1.2.3.4,5.6.7.8
```

## **snell.sh**

### 下载
```bash
curl -fSLO https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/snell.sh
```

### 参数说明
```text
-i, --install [VERSION] 安装，可指定版本
-n, --update [VERSION]  更新，可指定版本
-u, --uninstall         卸载
-p, --port PORT         监听端口，范围 10000-60000
-k, --psk PSK           预共享密钥，16 位字母数字
-h, --help              显示帮助
```

无参数时显示安装、更新、卸载菜单。

### 示例命令
```bash
bash snell.sh --install 4.1.1 --port 23456 --psk abcdefgh12345678
```

## **reality.sh**

### 下载
```bash
curl -fSLO https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/reality.sh
```

### 参数说明
```text
--protocol LIST                 reality、shadowsocks 或 reality,shadowsocks
--reality-port PORT             Reality 端口
--reality-domain DOMAIN         Reality 域名
--reality-uuid UUID             VLESS UUID
--reality-private-key KEY       Reality 私钥
--reality-public-key KEY        Reality 公钥
--reality-short-id ID           Reality short id
--ss-port PORT                  Shadowsocks 端口
--ss-password PASSWORD          Shadowsocks 密码
--socks-host HOST               Socks 服务 IP
--socks-port PORT               Socks 服务端口
--update                        更新 Xray
-u, --uninstall                 卸载 Xray
-h, --help                      显示帮助
```

安装时必须提供 `--protocol`；无参数会直接报错。

### 示例命令
```bash
bash reality.sh \
  --protocol reality,shadowsocks \
  --reality-domain game.granbluefantasy.jp \
  --reality-port 52080 \
  --ss-port 51080 \
  --socks-host 1.2.3.4 \
  --socks-port 1080
```

## **smartdns.sh**

### 下载
```bash
curl -fSLO https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/smartdns.sh
```

### 参数说明
```text
-e, --ecs REGION        ECS 区域: HK, TYO, MY, SG, LA, OR, SEA
-6, --ipv6 MODE         IPv6 模式: yes, no；未提供时沿用 SmartDNS 默认行为
--update                更新 SmartDNS
-u, --uninstall         卸载并恢复 DNS 为 1.1.1.1 / 8.8.8.8
-h, --help              显示帮助
```

无参数时安装 SmartDNS，或按当前参数更新配置。

### 示例命令
```bash
bash smartdns.sh --ecs TYO
```

## **mosdns.sh**

### 下载
```bash
curl -fSLO https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/mosdns.sh
```

### 参数说明
```text
-i, --install           显式安装，可省略
-d, --dns DNS           自定义 DNS 服务器
-e, --ecs REGION        ECS 区域: HK, TYO, MY, SG, LA, OR, SEA；默认 TYO
-4, --ipv4              IPv4 优先，默认模式
-6, --ipv6              IPv6 优先
-u, --uninstall         卸载
-h, --help              显示帮助
```

无参数时使用默认配置安装 MosDNS。

### 示例命令
```bash
bash mosdns.sh --install --ecs TYO --ipv4
```

## **kernel.sh**

### 下载
```bash
curl -fSLO https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/kernel.sh
```

### 参数说明
```text
-6 yes|no               是否保留 IPv6 配置，默认 yes
-u                      移除内核优化配置
-h, --help              显示帮助
```

无参数时应用默认内核网络优化配置。

### 示例命令
```bash
bash kernel.sh -6 no
```

## **nftables.sh**

### 下载
```bash
curl -fSLO https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/nftables.sh
```

### 参数说明
```text
--forward RULE [...]       设置转发，完整列表覆盖原有设置
--forward off              关闭转发
--whitelist ITEM [...]     设置白名单，完整列表覆盖原有设置
--whitelist off            关闭白名单，放行全部入站
--list                     查看当前设置
--uninstall                全部移除
-h, --help                 显示帮助
RULE                       源端口:目标IP或域名:目标端口[:SNAT_IP[:MSS]]
ITEM                       IP、IP段、域名、URL 或本地文件路径
```

白名单开启后，只有白名单内的来源可以访问本机和使用转发。URL 和本地文件更新后会自动生效。

### 示例命令
```bash
bash nftables.sh --forward 10086:1.2.3.4:33333 --whitelist /root/whitelist.txt home.example.com
```

## **sshg.sh**

### 下载
```bash
curl -fSLO https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/sshg.sh
```

### 参数说明
```text
--apply                 应用传入的 config/key 变更
--reset                 重置为传入的 config/key 状态
--remove                移除 sshg 托管的 SSH 配置与公钥
config=ssh              写入 SSH hardening 配置
key=...                 确保 root 可使用该 ssh-ed25519 公钥，必要时写入 authorized_keys3
-h, --help              显示帮助
```

无参数时显示帮助并返回失败，不会修改系统。SSH 端口的来源限制由 `nftables.sh --whitelist` 负责。

### 示例命令
```bash
bash sshg.sh --reset config=ssh key='ssh-ed25519 AAAA...'
```
