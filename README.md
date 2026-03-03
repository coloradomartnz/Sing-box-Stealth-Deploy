# 🚀 Sing-box Stealth Deploy
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Language-Bash-4EAA25.svg?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Systemd](https://img.shields.io/badge/Integration-Systemd-black.svg?logo=linux&logoColor=white)](https://systemd.io/)

**Sing-box Stealth Deploy** 是一款高度优化、模块化构架且极其稳定的 [sing-box](https://sing-box.sagernet.org/) 透明代理自动部署解决方案。本专案生而为追求**极致性能**、**系统洁癖**与**安全隔离**的 Linux 高级用户量身定制。只需一行代码，即可接管全局网络，让流媒体解锁和分流变得前所未有的简单。

---

## ✨ 核心特性

- 🧱 **完全模块化设计**：将复杂的部署过程拆分为 7 个清晰的步骤，易于审计、维护与自定义。
- ⚡ **并行加速**：Rulesets (规则集) 采用后台并行下载逻辑，显著缩短部署时间。
- 🛠️ **鲁棒性增强**：内部集成软错误处理 (Soft Failure)，即使面板下载失败，代理核心依然能稳定上线。
- 📊 **本地化面板**：自动部署 MetacubexD 本地面板，支持实时节点切换与流量监控。
- 🛡️ **安全加固**：原生集成 AppArmor 安全策略，提供进程级隔离。
- 🌍 **全协议支持**：支持 VLESS, VMess (WS), Trojan, Hysteria2, Tuic, NaiveProxy, Wireguard, Socks5 等协议。
- ⚡ **分流管理**：集成智能 DNS 分流 (Split-DNS) 与路由规则，自动识别国内外流量，支持 SNI 嗅探。
- 📺 **流媒体解锁**：脚本自动按地区 (HK/JP/US/SG等) 生成分组，配合 `urltest` 自动选择最优节点，助力解锁流媒体。
- 🌐 **双栈优化**：支持原生 IPv6 路径优化，提供端到端的 IPv6 透明代理能力。
- 🔍 **深度自检**：提供 `--check` 命令，对环境、配置、端口、连通性进行全方位健康扫描。
- 🧹 **无痕卸载**：支持深度卸载，能够彻底清理所有残留文件、系统配置与用户账号。

---

## 🛠️ 部署步骤 (1-7)

脚本按照严密的逻辑顺序执行：
1. **安装环境**：配置官方源并安装最新的 sing-box。
2. **结构部署**：配置持久化目录与辅助管理脚本。
3. **订阅构建**：集成 `sing-box-subscribe` 实现灵活的节点转换。
4. **规则预下载**：并行获取最新的路由过滤规则。
5. **面板安装**：自动化部署 MetacubexD UI。
6. **配置生成**：利用原子写入 (`_atomic_write`) 生成高可用配置文件。
7. **系统集成**：整合 Systemd、NetworkManager 及 AppArmor。

---

## 🚀 快速开始

### 1. 克隆/准备脚本并赋予执行权限
```bash
# 赋予主脚本及辅助模块执行权限
chmod +x singbox-deploy.sh cmd/*.sh steps/*.sh scripts/*.sh
```

### 2. 一键安装
```bash
sudo ./singbox-deploy.sh
```

### 3. 自动化模式 (无需交互)
```bash
sudo AUTO_YES=1 AIRPORT_URLS_STR="YOUR_URL" ./singbox-deploy.sh
```

### 4. 健康状态检查与自检进程 (Health Check)
```bash
sudo ./singbox-deploy.sh --check
```

### 5. 安全回滚 (Safe Rollback)
如果部署或升级后发现网络异常，脚本会自动创建双击备份。您可以随时回滚：
```bash
sudo ./singbox-deploy.sh --rollback
```
系统会列出最近的备份点，输入对应编号即可一键恢复原状。

---

## 🧪 测试与质量保证 (Testing)

本项目集成了一套完整的测试套件，涵盖了组件依赖、配置容错、原子锁机制及权限隔离等多个维度。如果您对代码库进行了修改，请务必运行测试以确保没有任何破坏性更改：

```bash
# 运行完整的集成测试与语法验证
bash tests/test_fixes.sh
```

---

## 🛠️ 自定义分流 (Custom Routing)

脚本支持通过简单的列表文件轻松自定义路由规则：

1. **强制直连**：编辑 `/usr/local/etc/sing-box/direct_list.txt`，每行输入一个域名（如 `baidu.com`）。
2. **强制代理**：编辑 `/usr/local/etc/sing-box/proxy_list.txt`，每行输入一个域名（如 `openai.com`）。
3. **生效方式**：编辑完成后，运行 `sudo ./singbox-deploy.sh --upgrade` 即可自动重新生成并应用配置，脚本会自动读取这些列表，并将它们精准注入到 sing-box 的路由逻辑和 DNS 解析规则中，确保该域名下的所有页面和二级域名内容都遵循您的设置。

---

## ⚙️ 环境要求
- **操作系统**: Ubuntu 22.04+ (推荐 24.04), Debian 11+
- **权限**: Root 权限
- **依赖**: curl, jq, git, python3-venv

---

## 🤝 贡献
欢迎提交 Issue 或 Pull Request 来完善这个项目。在提交代码前，请确保脚本通过语法校验：
```bash
bash -n singbox-deploy.sh steps/*.sh lib/*.sh
```

---

## 📄 开源协议
本项目采用 [MIT License](LICENSE) 许可。
