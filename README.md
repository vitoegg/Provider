# Provider

个人自用的网络工具箱：分流规则与服务器部署脚本。

## 🗂️ 规则 `RuleSet`

由 GitHub Actions 定期自动更新。

- `AGI` — AI 服务分流
- `Apple` — Apple 系统服务
- `Proxy` — AI、Telegram、日本流媒体等代理规则
- `Direct` — 国内直连域名与 IP
- `Extra` — MosDNS、AdGuard、sing-box、防火墙等专用规则

## 🛠️ 脚本 `Script`

- `Network` — 服务器一键部署：内核优化、防火墙、SmartDNS、sing-box、Shadowsocks、Snell 等，用法见 [README](Script/Network/README.md)
- `Task` — 论坛每日签到
- `Worker` — Cloudflare Worker，代理访问 GitHub 仓库文件
- `Workflow` — 规则生成与上游监控

> 💡 脚本主要通过 Vibe Coding 辅助编写。
