# Sing-box Deployment Tool

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Language-Bash-4EAA25.svg?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Systemd](https://img.shields.io/badge/Integration-Systemd-black.svg?logo=linux&logoColor=white)](https://systemd.io/)

Sing-box Deployment Tool 是一个面向 Linux 环境的 bash 脚本集，用于自动化部署和配置 [sing-box](https://sing-box.sagernet.org/) 透明代理。它结合了 eBPF 技术、系统服务集成与安全机制，为高级用户提供一套模块化、易维护的代理网络接管方案。

---

## 核心特性

- **模块化构建流程**：将部署分为环境准备、目录配置、订阅构建、规则更新、面板安装、配置渲染与系统集成等七个步骤，提升可维护性。
- **eBPF 流量接管**：集成 TC BPF (Traffic Control BPF)，挂载到网卡 ingress 路径上，实现将容器或主机流量直接导向内核 TUN 接口，绕过冗长的 iptables 链。
- **节点自动分组与流媒体解锁**：基于 Python 脚本自动识别订阅节点名称中的区域标签（支持 Emoji 旗帜或国家代码），生成对应地区的 `urltest` 自动测速出站，便于进行流媒体分流。
- **自定义分流策略**：支持通过 `direct_list.txt` 和 `proxy_list.txt` 基于文件导入域名，并使用 jq 自动转化为匹配的路由与 DNS 规则。
- **本地控制面板**：自动部署 MetacubexD 本地静态 UI，支持切换策略组与查看连接状态。
- **双栈及网络优化**：自动探测网络 MTU 并计算 TUN 设备的最佳 MTU 值；支持原生 IPv6 环境自适应配置。
- **Stealth+ 住宅 IP 扩展**：提供针对 AI 及流媒体等场景的可选扩展方案，支持将流量分发到自备的住宅代理（Residential Proxy），并配备 Watchdog 服务实现故障时向常规节点的自动回退。
- **系统层安全控制**：内置基于 AppArmor 的权限隔离配置，限制进程权限以保障宿主机安全。
- **生命周期管理**：提供健康检查 (`--check`)，配置回滚 (`--rollback`) 以及完整干净卸载 (`--uninstall`) 的运维命令。

---

## 目录结构说明

- `singbox-deploy.sh`: 主部署入口脚本。
- `steps/`: 具体各个部署阶段的分步脚本。
- `cmd/`: 命令行子命令（检查、卸载、回滚等）。
- `lib/`: 通用的 bash 工具函数库（检查、锁管理、输出日志等）。
- `scripts/`: 提供如配置生成、DNS 故障转移监控、区域分组 (`singbox_build_region_groups.py`) 等后台运行工具。
- `ebpf/`: 包含 C 语言编写的内核态 BPF 源码 (`tproxy_tc.bpf.c`)。
- `templates/`: 提供 systemd 服务单元、AppArmor 配置文件以及 sing-box `config.json` 的渲染模板。
- `tests/`: 包含脚本集的完整单元测试与集成测试环境（虚拟机、Docker 环境跑测）。

---

## 快速开始

### 1. 准备执行环境

克隆仓库后，确保所有相关脚本具备可执行权限：

```bash
chmod +x singbox-deploy.sh cmd/*.sh steps/*.sh scripts/*.sh
```

### 2. 标准交互式安装

在具有 root 权限下运行部署脚本，过程中按提示输入节点订阅地址及可选参数：

```bash
sudo ./singbox-deploy.sh
```

### 3. 非交互式自动安装

可通过环境变量注入参数，适用于无头服务器初始化的自动化配置：

```bash
sudo AUTO_YES=1 AIRPORT_URLS_STR="https://example.com/sub?name=MySub" ./singbox-deploy.sh
```

### 4. 状态检查与诊断

部署完成后，可以使用如下命令诊断服务健康状况（包括 eBPF 挂载、服务状态、连接测试）：

```bash
sudo ./singbox-deploy.sh --check
```

### 5. 服务回滚

若升级或修改后出现问题，你可以回滚到自动生成的可用旧版本配置：

```bash
sudo ./singbox-deploy.sh --rollback
```

---

## 自定义路由与分流

脚本会在部署目录 `/usr/local/etc/sing-box/` 建立两个控制列表：

1. **直连域名放行**：编辑 `direct_list.txt`，将不需要走代理的域名加入其中。
2. **强制代理名单**：编辑 `proxy_list.txt`，确保特定域名固定经由代理访问。

配置修改后运行以使其生效：
```bash
sudo ./singbox-deploy.sh --upgrade
```

---

## 环境要求

- **操作系统**: 推荐使用较新内核的发行版，如 Ubuntu 22.04+ (24.04 尤佳) 或 Debian 11+，以确保 eBPF 及 systemd 获得最佳支持。
- **运行权限**: 必须具有 `root` 或 `sudo` 权限。
- **依赖软件包**: `curl`, `jq`, `git`, `python3-venv`, `clang`, `llvm` (编译 eBPF 需要)。脚本在执行期间会自动尝试补充未安装的核心依赖。

---

## 测试与质量保障

如需参与开发修改代码，提交前可以通过内建的测试套件以验证修改不会带来语法错误或回归问题：

```bash
# 执行脚本语法检查
bash -n singbox-deploy.sh steps/*.sh lib/*.sh

# 执行单元及集成测试
bash tests/test_fixes.sh
```

---

## 许可证

本项目基于 [MIT License](LICENSE) 发布。

