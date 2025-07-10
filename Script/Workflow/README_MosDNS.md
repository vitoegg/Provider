# MosDNS规则更新自动化脚本

## 概述

这个自动化脚本用于每天凌晨3点更新MosDNS规则集，主要功能包括：

1. **自动下载**：从多个上游规则源下载最新规则
2. **格式转换**：将AdGuard Home规则转换为MosDNS格式
3. **智能过滤**：去除正则表达式规则和无效规则
4. **域名优化**：合并重复和包含关系的域名
5. **详细日志**：提供完整的处理过程和统计信息

## 文件结构

```
Provider/
├── .github/workflows/
│   └── update-mosdns-rules.yml          # GitHub Actions工作流
├── Script/Workflow/
│   ├── process_mosdns_rules.sh          # Shell主脚本
│   ├── process_mosdns_rules.py          # Python处理脚本
│   └── README_MosDNS.md                 # 本说明文档
└── RuleSet/Extra/MosDNS/
    └── reject.txt                       # 输出的MosDNS规则文件
```

## 规则来源

脚本从以下3个源获取规则：

1. **miaoermua/AdguardFilter**
   - URL: https://raw.githubusercontent.com/miaoermua/AdguardFilter/main/rule.txt
   - 格式: AdGuard Home规则

2. **TG-Twilight/AWAvenue-Ads-Rule**
   - URL: https://raw.githubusercontent.com/TG-Twilight/AWAvenue-Ads-Rule/main/Filters/AWAvenue-Ads-Rule-Mosdns_v5.txt
   - 格式: MosDNS规则

3. **vitoegg/Provider**
   - URL: https://raw.githubusercontent.com/vitoegg/Provider/master/RuleSet/Extra/MosDNS/reject.txt
   - 格式: MosDNS规则

## 处理流程

### 1. 规则下载
- 并行下载所有规则源
- 下载失败时跳过本次更新，保持本地规则不变
- 记录下载状态和耗时

### 2. 格式转换
支持以下AdGuard Home规则格式转换为MosDNS格式：

| AdGuard格式 | MosDNS格式 | 说明 |
|-------------|------------|------|
| `\|\|example.com^` | `domain:example.com` | 标准域名规则 |
| `\|\|example.com^$third-party` | `domain:example.com` | 带参数的域名规则 |
| `\|http://example.com` | `domain:example.com` | HTTP协议规则 |
| `\|https://example.com` | `domain:example.com` | HTTPS协议规则 |
| `.example.com` | `domain:example.com` | 泛域名规则 |
| `example.com` | `domain:example.com` | 简单域名规则 |
| `domain:example.com` | `domain:example.com` | 已是MosDNS格式 |
| `full:example.com` | `full:example.com` | 精确匹配规则 |

### 3. 规则过滤
自动过滤以下类型的规则：
- 注释行（`#` 或 `!` 开头）
- 允许规则（`@@` 开头）
- 正则表达式规则（包含 `*`, `^`, `$`, `|`, `[]`, `()`, `\`, `+`, `?`）
- 无效域名格式

### 4. 域名优化
- **去重**：移除完全相同的规则
- **包含关系合并**：如果存在 `example.com` 和 `sub.example.com`，只保留 `example.com`
- **排序**：按字母顺序排序最终规则

### 5. 变更检测
- 比较新旧规则的实际内容（忽略注释和时间戳）
- 统计新增、删除的规则数量
- 只有规则内容发生变化时才提交更新

## 执行计划

- **定时执行**：每天凌晨3点（北京时间）
- **手动触发**：可在GitHub Actions页面手动运行
- **失败处理**：下载失败时跳过更新，避免破坏现有规则

## 日志输出

脚本提供详细的处理日志，包括：

```
┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
┃ 🔄 MosDNS规则集处理: MosDNS拦截规则
┃ 📁 保存位置: /path/to/reject.txt
┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
┃ ⬇️ 正在下载规则数据...
┃   ✅ 下载成功: https://example.com/rule1.txt
┃   ✅ 下载成功: https://example.com/rule2.txt
┃ 🔄 正在合并规则数据...
┃ 📊 清理后的规则条数: 50000
┃ 🧹 正在对MosDNS规则进行专业清洗...
┃   ▶️ 使用MosDNS专用Python脚本进行规则处理...
┃   📋 MosDNS规则处理统计:
┃     处理时间: 2.34 秒
┃     总行数: 50000
┃     注释行: 5000
┃     允许规则: 100
┃     正则规则: 2000
┃     转换规则: 35000
┃     MosDNS格式: 8000
┃     重复规则: 1500
┃     被覆盖规则: 500
┃     最终保留: 40000
┃ 📊 优化后的规则条数: 40000 (减少了 10000 条)
┃ 📋 MosDNS规则变化详情:
┃   ➕ 新增规则: 150 条
┃   ➖ 移除规则: 80 条
┃ ✅ 规则文件已更新
┃ ⏱️ 处理完成，用时: 45 秒
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## 输出格式

生成的 `reject.txt` 文件格式：

```
# Customized Ads Rule for MosDNS
# Version: 2.0
# Homepage: https://github.com/vitoegg/Provider/tree/master/RuleSet/Extra/MosDNS
# Update time: 2024-01-01 03:00:00 UTC+8
# Converted from AdGuard Home format

# 规则来源:
# - https://github.com/miaoermua/AdguardFilter
# - https://github.com/TG-Twilight/AWAvenue-Ads-Rule
# - https://github.com/vitoegg/Provider

# Note: Allow rules (@@) are not supported in MosDNS reject list
# These rules should be added to allow list instead

domain:ads.example.com
domain:tracker.example.com
full:exact-match.com
...
```

## 使用方法

### 自动运行
脚本会自动在每天凌晨3点运行，无需手动干预。

### 手动运行
1. 在GitHub仓库页面，点击 "Actions" 标签
2. 选择 "Update MosDNS Rules" 工作流
3. 点击 "Run workflow" 按钮

### 本地测试
```bash
# 进入项目目录
cd Provider

# 给脚本添加执行权限
chmod +x Script/Workflow/process_mosdns_rules.sh
chmod +x Script/Workflow/process_mosdns_rules.py

# 运行脚本
./Script/Workflow/process_mosdns_rules.sh
```

## 错误处理

- **下载失败**：如果任何一个规则源下载失败，脚本会跳过本次更新
- **处理错误**：如果Python脚本执行失败，会回退到基础去重方法
- **格式错误**：无效的域名格式会被自动过滤掉
- **网络超时**：每个下载请求有30秒超时限制

## 维护说明

- 定期检查上游规则源的可用性
- 监控脚本执行日志，确保正常运行
- 根据需要调整规则源或处理逻辑
- 保持脚本和依赖的更新 