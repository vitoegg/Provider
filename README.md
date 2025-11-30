# Provider

个人自用的网络工具箱，包含 Loon/Surge 模块、分流规则集以及服务器配置脚本。

## 📂 仓库内容

### 1. 规则与模块 (Module & RuleSet)
适用于 Surge、Loon等代理工具的配置增强

- **Module**: 包含去广告、应用优化等功能插件。
    - 支持 Surge (`.sgmodule`)、Loon (`.plugin`)
- **RuleSet**: 精细化的分流规则，每日通过 GitHub Actions 自动更新。
    - `AGI`: OpenAI, Claude 等 AI 服务
    - `Apple`: Apple 系统服务与更新
    - `Proxy`: 常用代理服务 (Telegram, 流媒体等)
    - `Direct`: 国内直连规则
    - `Extra`: MosDNS、AdGuard 等特定软件规则

### 2. 网络脚本 (Script)
主要位于 `Script/Network` 目录，包含通过 AI 辅助编写的服务器/软路由配置工具：
- **基础配置**: 系统内核优化、网络流量监控、IP配置
- **服务部署**: MosDNS, Shadowsocks, Snell, Realm 等一键部署脚本
- **自动化任务**: `Script/Task` 下包含签到与检测脚本

## 🔗 参考来源
部分模块与规则引用自以下优质项目：
- Surge: [R-Store](https://github.com/zirawell/R-Store), [Qingr](https://surge.qingr.moe)
- Loon: [ProxyResource](https://github.com/luestr/ProxyResource), [Loon](https://github.com/linuszlx/Loon)

---
*本项目中的脚本主要由 Vibe Coding 辅助生成。*
