# Provider
引用公开规则来自定义Surge、Clash规则

1、规则包含RuleSet、Module

2、其中RuleSet以Surge为基础，Clash规则从Surge修改而来

3、Module仅支持Surge，且会引用Script中的js文件

## Conf
个人自用的参考配置

[General]
# 通用设置
# > 增强版 Wi-Fi 助理
# (在 Wi-Fi 网络不佳时尝试使用数据网络建立连接，请仅当使用不限量的数据流量时开启)
wifi-assist = false
# > Internet 测试 URL
internet-test-url = http://wifi.vivo.com.cn/generate_204
# > 代理测速 URL
proxy-test-url = http://cp.cloudflare.com/generate_204
# > 测试超时（秒）
test-timeout = 5
# > 自定义 GeoIP 数据库
geoip-maxmind-url = https://raw.githubusercontent.com/Loyalsoldier/geoip/release/Country.mmdb
# > IPv6 支持（默认关闭）
ipv6 = false
# > 允许 Wi-Fi 访问 (仅 iOS，若允许远程访问将「false」改为「true」)
allow-wifi-access = false
wifi-access-http-port = 5180
wifi-access-socks5-port = 5188
# > 允许 Wi-Fi 访问 (仅 macOS，若允许远程访问将「127.0.0.1」改为「0.0.0.0」)
http-listen = 127.0.0.1:5186
socks5-listen = 127.0.0.1:5187
# > 兼容模式 (仅 iOS)
# compatibility-mode = 0
# > 跳过代理
skip-proxy = 127.0.0.1, 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12, 100.64.0.0/10, localhost, *.local, captive.apple.com, seed-sequoia.siri.apple.com, cable.auth.com, iosapps.itunes.apple.com
# > 排除简单主机名
exclude-simple-hostnames = true
# > Network framwork
network-framework = false
# > DNS 服务器 (如无必要不建议使用 DNS over HTTPS)
dns-server = system
hijack-dns = 8.8.8.8:53, 8.8.4.4:53
# > 从 /etc/hosts 读取 DNS 记录
read-etc-hosts = true
# 高级设置
# > 日志级别
loglevel = notify
# > 当遇到 REJECT 策略时返回错误页
show-error-page-for-reject = true
# > Always Real IP Hosts
always-real-ip = *.lan, cable.auth.com, captive.apple.com
allow-hotspot-access = false
all-hybrid = true
http-api-web-dashboard = true

[Proxy]
Local = direct

[Proxy Group]
Network = select, Global, Local
Global = select, US, KR, IEPL, AC
AGI = select, US, Global
Speedtest = select, Local, Global

[Rule]
# HTTP3/QUIC 屏蔽
AND,((PROTOCOL,UDP), (DEST-PORT,443)),REJECT-NO-DROP
# > Privacy
DOMAIN-SET,https://github.com/vitoegg/Provider/blob/master/RuleSet/Extra/Privacy.list?raw=true,REJECT
# Apple服务策略
# > Apple System
RULE-SET,SYSTEM,Local
# > Apple Service
DOMAIN-SET,https://raw.githubusercontent.com/Loyalsoldier/surge-rules/release/apple.txt,Local
# > Apple iCloud
DOMAIN-SET,https://raw.githubusercontent.com/Loyalsoldier/surge-rules/release/icloud.txt,Local
# Wechat直连
RULE-SET,https://github.com/blackmatrix7/ios_rule_script/blob/master/rule/Surge/WeChat/WeChat.list?raw=true,Local
# China直连
DOMAIN-SET,https://github.com/vitoegg/Provider/blob/master/RuleSet/Direct/China.list?raw=true,Local
# 个性化服务
# > AGI
DOMAIN-SET,https://github.com/vitoegg/Provider/blob/master/RuleSet/Proxy/agi.list?raw=true,AGI
# > Speedtest
DOMAIN-SET,https://github.com/vitoegg/Provider/blob/master/RuleSet/Extra/Speedtest.list?raw=true,Speedtest
# Global服务
# > Telegram
RULE-SET,https://github.com/VirgilClyne/GetSomeFries/blob/main/ruleset/ASN.Telegram.list?raw=true,Global
# > Global 加速
DOMAIN-SET,https://raw.githubusercontent.com/Loyalsoldier/surge-rules/release/proxy.txt,Global
# > 终极规则
IP-CIDR,0.0.0.0/32,REJECT,no-resolve
RULE-SET,LAN,Local
GEOIP,CN,Local
FINAL,Network,dns-failed

[MITM]
skip-server-cert-verify = true
tcp-connection = true
h2 = true
hostname = -gateway.icloud.com, -gateway.icloud.com.cn, -weather-data.apple.com, -buy.itunes.apple.com
ca-passphrase = F52VE5LMAM
ca-p12 = MIIJ0QIBAzCCCZcGCSqGSIb3DQEHAaCCCYgEggmEMIIJgDCCBDcGCSqGSIb3DQEHBqCCBCgwggQkAgEAMIIEHQYJKoZIhvcNAQcBMBwGCiqGSIb3DQEMAQYwDgQIZBFiELGbvGgCAggAgIID8B9YPOQ9EZpOQqKADQc/8BxEo4cCAjSfjd90BaThe+ebf2YTSMmo/bxOJk2ta03LxE73XuFQTDMv/0ATlbjhmYls1gNH5gG4pMCEofL7d9xwbgOTJEOfRyqL3uDfR2dI9Yswxv79M0pAWNRkiBVsaN8+jghWmY1spY1Rp1QUaHOQ4grCXrgsmTvFX2L7wtTMNcmLdv00Z9wSqa0jYZGA5pPvGrhVLyCrkPO2XYGPFfH5w9Wc37yYh0BTnj1oBS7L2CAUQj0fWW1RFJIheYRQJFAPmeF9N6Woxhd0pxVAOHJB3RnK+gK6KlXi1k7+N/jsqliXFn0V7kjYGce8Qt/eoEgIAk8mNEyjFC/2IFLshqKh6prPQnuPHX/qXygzYIn48kXSErssBc3fvsnbvwwfxc6+ZKS0QKSei8od2CO7RCrq0MHI15QLEelYpV7fhUHKLdV8N6QAIpF0y9UXJ7ay16T9LUmsgwHIJo7twF83H8sIbqhhUuad2f5C41q988vYCf72QBcRdSJo8F3bxbOJLEY5ATgeWAqyEpxUFIM9ihVmSmxSikR89Xp7FYKsr38vo0ZSuSwjE0Nw/sKT4SvDLiCEt76jLtNxtqMrPceskhVXh+PHUC4B4MQ9aDN6xPERzPh00M0HBwp04ydqnYZzHvDIfibU/sAawIdoKw5Ci0ZsbztkoOVPyAlSIjtLrEg13uGhZLyElCUR18+aHuR9udxkqO1FtYT3S1dpcN6FfV8xepHLYnPoIiCMJZ3lnpatCf9CIkJFj7XAD+o4Rv5ILqHy2/o1dh2r+nchYELpm+j/h0Tum2GOmyPOYRNykxQ64q3177DNd9Zd5gBGPlIL/8vmxBkUp6OrxYilV2Ri2QYN/MpCu6GtDFgImiPBZxqY6qybgmtrHDvPYOIzxx2vkzgyIb/BK190XutQgSTHbjQrgKHlHHEh1Wy6AhIUDpiEEWb4bKO3pgxvH19OqbdcO28VFVjkLqcOersVN0PZPoO9QgHneXxps0sshgt4F2puj5l3PmCI3rd/4VaFKFGhfgEG5yPzuJvcHTN6m2w1BkMQrAE4IxW9npugX2yRtGxbQEh0uvNZPn4qWIBElo2et8P1pouDoMT6B7snZSOuIjoCvJj7toBZUemIWHKUxt2VTHTru6tsWoVs6QR7EklauXEtD02eYk0Loi4KWERdqgHuCDTdYd8KL9x/a7MZl//WnD+ACdypsZNOoKVIDbNBRHsnuP9RwX2s/J1xmGR1VkgyIUfC8M3QDpfFyMtfR+2q8lZDZlwLSdFcyf3ST6Mc1xwCmTmTkC3W5tT3jH6B5wQI9dNiAhvbwvBOF0ezClY7KTCCBUEGCSqGSIb3DQEHAaCCBTIEggUuMIIFKjCCBSYGCyqGSIb3DQEMCgECoIIE7jCCBOowHAYKKoZIhvcNAQwBAzAOBAiK2+VOib7G3gICCAAEggTIMFZaX2yHs7vb+cBONqg7r44YacFC+MS2vr/Q/ArHOuZOm7FQ2kRYCPZOVIGqS8wz7KiacTeiIDdr0dogva0t0WrWYnjASOmEih0UrgKznPVqtJVN9Ruq85d3vHXNIr33Jjh2VwP6KEZN6ct0mkTG0xJapHdiju13HPRCc8aFI0D30pser6mftAaDJdWTvBBgVkpwte44Ui06kV4RWKRUX0MGYA0WRXF+Tau3JMkuGMLcxi/FhChu9m76O+MJA9jtZCMi5t+1MH7HjDfN6CQHVszTNZaOy3UM9PDOeyv9SwpN4Gz7DFL+p/s3R28NamTzgnbomlbNfPdJ4SWdrMdP0IqYyYuQ/xBgvIsPRHGtvP0QDGTq3kMqIHXcCnoU/lzSF0zaGauyq6ykZTTTK0FwImMQ/7/lx2v6HU/4jW6DbzOJqDzpbuP14A4FJUf//K5xHNbdwKIO7wn7g2bNlzKC9LhdlIEHL5d5dFMq5HVEQ46j0dPUyWSXQzzocHHbsuFznnnkofJf30Bidvpa6C50/xXZ5vUAdHJqmSe1ZhQv+yWwgxJ89/K1y171uysMjf+njTHJTpUjYyw6sHI8wxTtQlENZymiBAccMpLNwDOrcJhQhdqagd7Ppf6vX6LTMzAtI8suicgLWRyW0Cccr9l6LjTflDBKGX4N0z+QnR78HPYYifbrfiAzeruU9ctfdJmwDktDPLSpoRBt4HdZmu5GwPg/5r3SdPVTIK5knxUn6TB38obJjsvFJhuyEFE+T/Qn6rxNRDrFNk20fGumXV+WSxzbnd7c0YnPD19qLBzd1gvV9tXzb2abOksy71Cgtxxv4ZeGTJQ2qsxkntJivHYvnagQfS43wOrW+T7kKRUz1FLFPb69A6izwrAHcb1SGtChbMt71o3XBZoJM5G6wlI/2K7eSBVzALggerg+AHzoNJeDK2Igd0pgaiSq/qodpLUMzFLvwC3V71SMh2KtrTcUtp7ObpHhYIuBOuuoE7Jhxe/vmMFBhXD8f4IPplaoaDpRkwsC/OMdMCCoVZm3A1ckbqLnN9IqNROgw2TwEUkjky+1wnLH8GtwSWnwUj0QQlp5FnGNs8EU6FySKQs+edHaEskmfM7VraL1RYONBLgK8qhMf+uiFm2oI2NSJ2TWLi1R1se4GRlFBXIDqbkjVZ+CcguvFZRD+Y30yCqfGEvPIReUmSjmrnfldNjXtP/M532OZwWQCqzhSdKL/ivn9Fe4IaT6Wfcp7bamXMTFlqwzuYMC/QrbjMVRHUdVVnBgW/PrXcRHSBjGHKdQKk6ebUB4qAep6GW9MvPi2RSrPzFYQFGxnTs9zIf/5UzBgK2fQnebXmDVREa4jClYbHD72nA/+3+TydFnZrYvj4oP2B7z2hWHvbYdmPiV0+T0/ipJP2bltSOSWhcJ/luEkLTa8gfFMUVjp2Y8rMtOurK4b5oo9/wCvLpzcXotoAPHo4BMx9Ojk5I88uGA5Jg2K7pDKPqZHKUaiEj6jQRBEuKpl2F0QTPPN3cQKxs1WnKYTbHuTSzvaOq6B28vUIIKq2xw5vZ+Zy9DCEga4a+KndV3sTKj+sxT3wh1Ba7Ig1FMUnxyWYLodqiLnHXob8rt9Cs3mMLHg0A2h/I2BGLYMSUwIwYJKoZIhvcNAQkVMRYEFOJm2rYqA/5s6PsDEfxiOsq/0bUBMDEwITAJBgUrDgMCGgUABBRl4rqV2hYtSOKVjRd0kgDk6dQACgQIWN9CjAW8zjkCAggA

## Module Links
Module包含自定义和外部引用，为了保持及时更新不使用CDN链接。

`AdScript`

- https://raw.githubusercontent.com/vitoegg/Provider/master/Module/AdScript.sgmodule


`连接模式`

- https://raw.githubusercontent.com/vitoegg/Provider/master/Module/OutboundMode.sgmodule

`高德地图去广告`

- https://raw.githubusercontent.com/kokoryh/Script/master/Surge/module/amap.sgmodule

`小红书去广告`

- https://github.com/kokoryh/Script/blob/master/Surge/module/xiaohongshu.sgmodule




