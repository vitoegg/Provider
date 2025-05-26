# Network Scripts 统一文档

这是一个网络配置和代理服务脚本集合，包含了多种网络工具的自动化安装和配置脚本。所有脚本都需要root权限运行，并支持主流的Linux发行版（Debian/Ubuntu）。

## 📋 脚本概览

| 脚本名称 | 功能描述 | 主要用途 |
|---------|---------|---------|
| `singbox.sh` | Shadowsocks 统一安装脚本 | 安装 ShadowTLS 和 SS2022 服务 |
| `tcp.sh` | TCP 优化配置脚本 | 系统网络性能优化 |
| `nftables.sh` | nftables 端口转发脚本 | 现代防火墙端口转发管理 |
| `shadowtls.sh` | ShadowTLS 服务安装脚本 | ShadowTLS 和 Shadowsocks 服务部署 |
| `iptables.sh` | iptables 端口转发脚本 | 传统防火墙端口转发管理 |
| `shadowsocks.sh` | Shadowsocks 安装脚本 | Shadowsocks-rust 服务部署 |
| `snell.sh` | Snell 代理服务脚本 | Snell 代理服务器安装配置 |
| `ssh_keys.sh` | SSH 密钥配置脚本 | SSH 公钥认证配置 |
| `traffic.sh` | 流量监控脚本 | 服务器流量限制和监控 |
| `ipconfig.sh` | IP 优先级配置脚本 | IPv4/IPv6 优先级设置 |
| `smartdns.sh` | SmartDNS 安装脚本 | 智能DNS服务器部署 |

## 🚀 详细功能介绍

### 1. singbox.sh - Shadowsocks 统一安装脚本

**功能特性：**
- ✅ 支持选择性安装：ShadowTLS、SS2022 或两者都安装
- ✅ 支持通过命令行参数指定配置
- ✅ 自动生成安全的密码
- ✅ 友好的日志输出和进度显示
- ✅ 支持卸载功能

**使用方法：**
```bash
# 交互式安装
sudo ./singbox.sh

# 命令行参数安装
sudo ./singbox.sh --install-shadowtls
sudo ./singbox.sh --install-ss2022
sudo ./singbox.sh --install-both

# 智能检测安装（推荐）
sudo ./singbox.sh --tls-port 58568 --tls-password mypass
sudo ./singbox.sh --ss2022-port 31606 --ss2022-password mypass

# 卸载
sudo ./singbox.sh --uninstall
```

**配置参数：**
- `--tls-port`: TLS 端口（默认：50000-60000随机）
- `--tls-password`: TLS 密码（默认：随机生成）
- `--tls-domain`: TLS 域名（默认：随机选择预设域名）
- `--ss-password`: Shadowsocks 密码（默认：随机生成）
- `--ss2022-port`: SS2022 端口（默认：20000-40000随机）
- `--ss2022-password`: SS2022 密码（默认：base64编码）

### 2. tcp.sh - TCP 优化配置脚本

**功能特性：**
- 🔧 IP 转发配置
- 🔧 IPv6 禁用选项
- 🔧 TCP 性能优化
- 🔧 支持多种配置组合
- 🔧 预设优化参数（HK、JP、自定义）

**使用方法：**
```bash
sudo ./tcp.sh
```

**配置选项：**
1. IP Forwarding - 启用IP转发
2. IPv6 Disable - 禁用IPv6
3. TCP Optimization - TCP性能优化

**预设配置：**
- HK Frenzy: Rmem=9699328, Wmem=9699328
- JP Frenzy: Rmem=33554432, Wmem=16777216
- Custom: 用户自定义缓冲区大小

### 3. nftables.sh - nftables 端口转发脚本

**功能特性：**
- 🔥 现代化防火墙管理
- 🔥 TCP/UDP 端口转发
- 🔥 本地和远程转发支持
- 🔥 规则查看和管理
- 🔥 自动IP转发配置

**使用方法：**
```bash
sudo ./nftables.sh
```

**主要功能：**
- 添加端口转发规则
- 查看当前转发规则
- 删除指定规则
- 清空所有规则

### 4. shadowtls.sh - ShadowTLS 服务安装脚本

**功能特性：**
- 🛡️ ShadowTLS 和 Shadowsocks 服务安装
- 🛡️ 支持多种系统架构
- 🛡️ 自动依赖包安装
- 🛡️ 服务管理功能

**使用方法：**
```bash
# 命令行参数安装
sudo ./shadowtls.sh --ss-port 8388 --ss-pass mypass --tls-port 443 --tls-pass tlspass --tls-domain example.com
```

**参数说明：**
- `--ss-port`: Shadowsocks 端口
- `--ss-pass`: Shadowsocks 密码
- `--tls-port`: TLS 端口
- `--tls-pass`: TLS 密码
- `--tls-domain`: TLS 域名

### 5. iptables.sh - iptables 端口转发脚本

**功能特性：**
- 🔧 传统防火墙端口转发
- 🔧 TCP/UDP 协议支持
- 🔧 自动IP检测
- 🔧 规则持久化

**使用方法：**
```bash
sudo ./iptables.sh
```

**功能：**
- 自动检测内网和公网IP
- 添加端口转发规则
- 查看当前转发规则
- 清空所有规则

### 6. shadowsocks.sh - Shadowsocks 安装脚本

**功能特性：**
- 🔐 Shadowsocks-rust 服务安装
- 🔐 版本检测和更新
- 🔐 多架构支持
- 🔐 自动配置生成

**使用方法：**
```bash
# 交互式安装
sudo ./shadowsocks.sh

# 命令行参数
sudo ./shadowsocks.sh -s password -p port
```

**参数：**
- `-s`: 指定密码
- `-p`: 指定端口
- `-h`: 显示帮助

### 7. snell.sh - Snell 代理服务脚本

**功能特性：**
- 🚀 Snell 代理服务器安装
- 🚀 版本管理
- 🚀 配置验证
- 🚀 服务状态监控

**使用方法：**
```bash
sudo ./snell.sh
```

**配置要求：**
- 端口范围：10000-60000
- PSK：16位字母数字字符

### 8. ssh_keys.sh - SSH 密钥配置脚本

**功能特性：**
- 🔑 SSH 公钥认证配置
- 🔑 禁用密码登录
- 🔑 自动权限设置
- 🔑 SSH 服务重启

**使用方法：**
```bash
sudo ./ssh_keys.sh -k "ssh-rsa AAAAB3NzaC1yc2E... user@host"
```

**参数：**
- `-k`: SSH 公钥（必需）
- `-h`: 显示帮助

### 9. traffic.sh - 流量监控脚本

**功能特性：**
- 📊 月度流量限制
- 📊 自动流量重置
- 📊 多种检查模式
- 📊 超限自动阻断

**使用方法：**
```bash
# 参数顺序：限制(GB) 重置日期 检查类型 网络接口
./traffic.sh 195 1 3 eth0
```

**检查类型：**
1. 只检查上传流量
2. 只检查下载流量
3. 检查上传和下载流量中的最大值
4. 检查上传和下载流量的总和

### 10. ipconfig.sh - IP 优先级配置脚本

**功能特性：**
- 🌐 IPv4/IPv6 优先级设置
- 🌐 网络连接验证
- 🌐 配置状态检查
- 🌐 美观的界面输出

**使用方法：**
```bash
sudo ./ipconfig.sh -v4    # 设置IPv4优先
sudo ./ipconfig.sh -v6    # 设置IPv6优先
sudo ./ipconfig.sh -u     # 恢复默认设置
```

### 11. smartdns.sh - SmartDNS 安装脚本

**功能特性：**
- 🔍 智能DNS服务器安装
- 🔍 自定义DNS配置
- 🔍 域名列表管理
- 🔍 版本自动检测

**使用方法：**
```bash
# 默认安装
sudo ./smartdns.sh

# 自定义DNS服务器
sudo ./smartdns.sh -d 8.8.8.8

# 卸载
sudo ./smartdns.sh -u
```

## 🛠️ 系统要求

### 支持的操作系统
- Debian 9+
- Ubuntu 18.04+
- 其他基于Debian的发行版

### 支持的架构
- x86_64 (amd64)
- aarch64 (arm64)
- armv7l (arm)
- i386/i686

### 必需权限
- Root 权限（所有脚本都需要）

### 自动安装的依赖
- `wget` - 文件下载
- `curl` - HTTP请求
- `jq` - JSON解析
- `openssl` - 加密功能
- `systemctl` - 服务管理
- `iptables/nftables` - 防火墙管理

## 📝 使用注意事项

### 安全建议
1. **生产环境使用前请先在测试环境验证**
2. **建议手动指定密码而不是使用随机生成**
3. **定期更新服务到最新版本**
4. **确保防火墙配置正确**

### 网络配置
1. **确保防火墙允许配置的端口通过**
2. **SS2022 密码必须是 base64 编码格式**
3. **端口配置避免与系统服务冲突**

### 服务管理
```bash
# 查看服务状态
sudo systemctl status [service-name]

# 启动/停止/重启服务
sudo systemctl start/stop/restart [service-name]

# 查看服务日志
sudo journalctl -u [service-name] -f
```

### 故障排除
1. **检查服务日志**：`sudo journalctl -u [service-name] -n 50`
2. **检查端口占用**：`sudo netstat -tulpn | grep :端口号`
3. **验证配置文件**：检查相应的配置文件语法
4. **检查防火墙规则**：确认端口未被阻止

## 🔄 更新和维护

### 脚本更新
- 脚本会自动从GitHub下载最新版本的服务
- 建议定期检查脚本更新
- 重要更新会在README中说明

### 配置备份
```bash
# 备份重要配置文件
sudo cp /etc/sing-box/config.json /etc/sing-box/config.json.bak
sudo cp /etc/shadowsocks-rust/config.json /etc/shadowsocks-rust/config.json.bak
```

## 📞 技术支持

如果在使用过程中遇到问题：

1. 查看脚本输出的错误信息
2. 检查系统日志：`sudo journalctl -xe`
3. 确认系统满足最低要求
4. 验证网络连接正常

## 📄 许可证

本脚本集合遵循相应的开源许可证，具体请查看各个项目的许可证文件。

---

**最后更新：** 2024年
**维护者：** System Administrator
**版本：** 2.0 