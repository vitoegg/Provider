# Network Scripts

## **singbox.sh**

### 下载
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/singbox.sh
```

### 参数说明
```text
--protocol LIST                 anytls、shadowsocks、shadowtls，支持逗号组合
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
--ss-port PORT                  Shadowsocks 端口
--ss-password PASSWORD          Shadowsocks 密码
--socks-host HOST               Socks 服务 IP
--socks-port PORT               Socks 服务端口
--version VERSION               sing-box 版本
--update                        更新 sing-box
-u, --uninstall                 卸载 sing-box
-h, --help                      显示帮助
```

安装时必须提供 `--protocol`；无参数会直接报错。

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
```

## **shadowsocks.sh**

### 下载
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/shadowsocks.sh
```

### 参数说明
```text
-s password             Shadowsocks 密码
-p port                 Shadowsocks 端口
-u                      卸载
-h, --help              显示帮助
```

无参数时显示安装、更新、卸载菜单。

### 示例命令
```bash
bash shadowsocks.sh -s password -p 25252
```

## **socks.sh**

### 下载
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/socks.sh
```

### 参数说明
```text
--port PORT                 监听端口，未提供时自动生成
--allow-ip IP[,IP...]       Dante 与 NFT 白名单 IPv4，必填且可重复使用
-u, --uninstall             卸载 Dante
-h, --help                  显示帮助
```

安装时 `--allow-ip` 必填；无参数会直接报错。

### 示例命令
```bash
bash socks.sh --port 28080 --allow-ip 1.2.3.4,5.6.7.8
```

## **snell.sh**

### 下载
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/snell.sh
```

### 参数说明
```text
-i, --install [VERSION] 安装，可指定版本
-n, --update [VERSION]  更新，可指定版本
-u, --uninstall         卸载
-p, --port PORT         监听端口
-k, --psk PSK           预共享密钥
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
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/reality.sh
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
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/smartdns.sh
```

### 参数说明
```text
-e, --ecs REGION        ECS 区域: HK, TYO, LA, OR, SEA
-6, --ipv6 MODE         IPv6 模式: yes, no
-u, --uninstall         卸载并恢复 DNS 为 1.1.1.1 / 8.8.8.8
-h, --help              显示帮助
```

无参数时安装 SmartDNS，或更新现有配置。

### 示例命令
```bash
bash smartdns.sh --ecs TYO
```

## **mosdns.sh**

### 下载
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/mosdns.sh
```

### 参数说明
```text
-i, --install           显式安装，可省略
-d, --dns DNS           自定义 DNS 服务器
-e, --ecs REGION        ECS 区域: HK, TYO, LA, OR, SEA
-4, --ipv4              IPv4 优先
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
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/kernel.sh
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
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/nftables.sh
```

### 参数说明
```text
--help, -h              显示帮助
--list, -l              查看规则
--add, -a [noping] RULE [...]    添加规则，可选禁止 ping
--delete, -d RULE [...] 删除规则
--replace, -r [noping] RULE [...] 替换全部规则，可选禁止 ping
--ddns sync             同步域名订阅
--ddns apply            应用 DNS cache
--ddns list             查看域名规则
--protect on [noping]   开启端口保护并保留转发，可选禁止 ping
--protect only [noping] 清空转发并仅开启保护，可选禁止 ping
--protect off           关闭端口保护
--protect status        查看保护状态
--protect sync          同步保护端口
--uninstall, -u         卸载脚本产物

RULE: <源端口>:<目标(IPv4/域名/local)>:<目标端口>[:SNAT_IP[:MSS]]
```

无参数时显示帮助并返回失败，不会修改系统。

### 示例命令
```bash
bash nftables.sh --add 10086:82.40.1.2:33333:10.100.1.2:auto
```

## **telegramip.sh**

### 下载
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/telegramip.sh
```

### 参数说明
```text
--apply                 下载远程 NFT，创建或替换 Telegram IP 映射
--remove                删除 Telegram IP 映射和持久规则文件
--help, -h              显示帮助
```

无参数时显示帮助并返回失败，不会修改系统。

### 示例命令
```bash
bash telegramip.sh --apply
```

## **sshg.sh**

### 下载
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/sshg.sh
```

### 参数说明
```text
--apply                 应用传入的 config/key/allow 变更
--reset                 重置为传入的 config/key/allow 状态
--sync                  解析域名并刷新 nft
--remove                移除 sshg 文件和 nft table
config=ssh              写入 SSH hardening 配置
key=...                 确保 root 可使用该 ssh-ed25519 公钥，必要时写入 authorized_keys3
allow=...               IPv4、IPv4 CIDR 或域名，逗号分隔
-h, --help              显示帮助
```

无参数时显示帮助并返回失败，不会修改系统。

### 示例命令
```bash
bash sshg.sh --reset config=ssh allow=1.2.3.4,1.2.3.0/24,example.com key='ssh-ed25519 AAAA...'
```

## **providerdns.sh**

### 下载
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/providerdns.sh
```

### 参数说明
```text
--install                           安装或修复 systemd timer
--set <consumer> <file> <hook>      注册订阅和 hook
--unset <consumer>                  移除订阅
--refresh                           刷新 DNS cache
--refresh hooks                     刷新 DNS cache 并运行受影响 hook
--cache <domain>                    输出缓存记录
--lookup <domain>                   输出缓存或即时解析 IPv4
--cleanup unused                    无订阅时清理运行时
-h, --help                          显示帮助
```

无参数时显示帮助并返回失败，不会修改系统。

### 示例命令
```bash
bash providerdns.sh --lookup example.com
```

## **warp.sh**

### 下载
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/warp.sh
```

### 参数说明
```text
--account ID             本地账户 ID，必须和 --name 成对出现；可重复使用
--name NAME              WARP 设备名称，必须紧跟对应的 --account
--license KEY            WARP+ license，对全部账户生效
--remove, -u             清理全部 WARP 配置和生成产物
-h, --help               显示帮助
```

无参数时显示错误并返回失败，不会修改系统。

### 示例命令
```bash
bash warp.sh --account account-a --name device-a --account account-b --name device-b
```

## **run.sh**

### 下载
```bash
wget -N https://raw.githubusercontent.com/vitoegg/Provider/master/Script/Network/run.sh
```

### 参数说明
```text
-h, --help              显示帮助
/path/to/cloudserver.plan 执行 plan 文件
```

### 示例命令
```bash
bash run.sh /path/to/cloudserver.plan
```
