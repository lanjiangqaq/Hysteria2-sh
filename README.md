# Hysteria 2 自动化部署脚本

本项目提供一键式的 Hysteria 2 服务端自动化部署与管理解决方案。脚本集成了核心组件安装、TLS 证书自动化申请以及服务端配置文件的动态生成，旨在降低部署门槛并提升节点安全性与网络性能。

## 核心功能

* **官方核心部署**：自动拉取并安装最新版 Hysteria 2 官方二进制程序。
* **自动化证书管理**：集成 `acme.sh`，支持 Let's Encrypt 证书自动签发与续期，内置 80 端口智能释放与环境恢复机制。
* **抗封锁与主动防御**：支持由用户自定义服务端伪装站点（Masquerade URL），有效防御防火墙与审查者的主动探测（Active Probing）。
* **性能参数随机化**：在每次部署时动态生成合理的 QUIC 接收窗口（Receive Window）参数，优化网络传输性能并规避固定参数带来的流量特征固化。
* **交互式管理菜单**：提供终端可视化的数字选项菜单，支持一键完整安装与彻底卸载（包含后台进程清理、配置文件移除及脚本自毁）。

## 环境与系统要求

* **支持的操作系统**：Ubuntu / Debian / CentOS / RHEL / AlmaLinux / Rocky Linux / openSUSE / Arch Linux。
* **权限要求**：必须使用 `root` 权限（或具有完整 `sudo` 权限的用户）执行此脚本。
* **网络与解析配置**：
  * 必须拥有一个真实域名，并已通过 DNS A 记录正确解析至当前服务器 IP。
  * 服务器防火墙必须放行 `80/TCP` 端口（用于 Let's Encrypt 证书 HTTP 验证）以及部署时自定义的 `UDP` 端口（用于 Hysteria 2 数据传输）。

## 快速开始

在服务器终端依次执行以下指令即可启动部署流程：
# 1. 下载脚本
wget -O hy2.sh https://raw.githubusercontent.com/lanjiangqaq/Hysteria2-sh/main/hy2.sh

# 2. 赋予执行权限
chmod +x hy2.sh

# 3. 运行脚本进入主菜单
./hy2.sh
