#!/bin/bash
# Hysteria2 Automated Installation & Management Script (Production Edition)
# Author: Modified for Production & Security, Port Hopping

set -o pipefail

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

HY_DIR="/etc/hysteria"
NODE_INFO_FILE="${HY_DIR}/node_info.env"

if [[ $EUID -ne 0 ]]; then
    clear
    echo -e "${RED}错误: 此脚本必须以 root 权限运行!${RESET}" 1>&2
    exit 1
fi

# ================= 基础环境检测与配置获取 =================
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DETECTED_OS="$NAME"
        OS_VERSION="$VERSION_ID"
    else
        DETECTED_OS=$(uname -s)
        OS_VERSION=$(uname -r)
    fi
}

get_user_input() {
    echo -e "${CYAN}===== 基础配置信息获取 =====${RESET}"

    while true; do
        read -rp "请输入您已解析至本机的真实域名 (必须包含 '.', 用于申请证书与 SNI): " DOMAIN
        [ -n "$DOMAIN" ] && break
        echo -e "${RED}错误: 域名不能为空，请重新输入。${RESET}"
    done

    while true; do
        read -rp "请输入您的合法邮箱 (用于接收证书到期通知，例如 admin@example.com): " EMAIL
        if [[ "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            break
        fi
        echo -e "${RED}错误: 邮箱格式不合法，请重新输入标准的邮箱地址。${RESET}"
    done

    echo -e "${CYAN}===== 伪装站点设置 =====${RESET}"
    echo "说明: 当防火墙或审查者主动探测您的节点时，服务端将向其展示该网站的内容。"
    read -rp "请输入防主动探测的伪装网站 URL (默认: https://www.tesla.com): " MASQUERADE_URL
    if [ -z "$MASQUERADE_URL" ]; then
        MASQUERADE_URL="https://www.tesla.com"
    elif [[ ! "$MASQUERADE_URL" =~ ^https?:// ]]; then
        MASQUERADE_URL="https://${MASQUERADE_URL}"
    fi
    echo -e "${CYAN}============================${RESET}"
}

install_packages() {
    detect_os
    echo "检测到操作系统: $DETECTED_OS $OS_VERSION"

    if command -v apt-get &> /dev/null; then
        apt-get update -y
        apt-get install -y curl wget openssl gawk ca-certificates socat lsof psmisc iptables cron
    elif command -v dnf &> /dev/null; then
        dnf install -y curl wget openssl gawk ca-certificates socat lsof psmisc iptables cronie
    elif command -v yum &> /dev/null; then
        yum install -y epel-release
        yum install -y curl wget openssl gawk ca-certificates socat lsof psmisc iptables cronie
    elif command -v pacman &> /dev/null; then
        pacman -Sy --noconfirm curl wget openssl gawk ca-certificates socat lsof psmisc iptables cronie
    else
        echo "错误: 未找到支持的包管理器，请手动安装依赖。"
        exit 1
    fi

    if command -v systemctl &> /dev/null; then
        systemctl enable crond 2>/dev/null || systemctl enable cron 2>/dev/null
        systemctl start crond 2>/dev/null || systemctl start cron 2>/dev/null
    fi
}

check_systemd() {
    command -v systemctl &> /dev/null
}

generate_password() {
    if [ -f /proc/sys/kernel/random/uuid ]; then
        HYSTERIA_PASSWORD=$(tr -d '-' < /proc/sys/kernel/random/uuid | head -c 16)
    else
        HYSTERIA_PASSWORD=$(openssl rand -hex 8)
    fi
}

get_port() {
    read -t 15 -rp "回车或等待15秒为随机主端口，或者自定义主监听端口请输入(1-65535): " SERVER_PORT
    if [ -z "$SERVER_PORT" ]; then
        if command -v shuf &> /dev/null; then
            SERVER_PORT=$(shuf -i 2000-65000 -n 1)
        else
            SERVER_PORT=$((RANDOM % 63000 + 2000))
        fi
    fi

    if ! [[ "$SERVER_PORT" =~ ^[0-9]+$ ]] || [ "$SERVER_PORT" -lt 1 ] || [ "$SERVER_PORT" -gt 65535 ]; then
        echo "错误: 端口必须是 1-65535 之间的数字"
        exit 1
    fi

    echo -e "${CYAN}===== 端口跳跃 (Port Hopping) =====${RESET}"
    echo "说明: 启用端口跳跃有效防止运营商对单端口的 QoS 限速或阻断。"
    read -rp "是否启用端口跳跃功能? [y/N]: " ENABLE_PORT_HOP
    if [[ "$ENABLE_PORT_HOP" =~ ^[Yy]$ ]]; then
        while true; do
            read -rp "请输入端口跳跃的范围 (直接回车默认 30000-50000): " PORT_HOP_RANGE
            PORT_HOP_RANGE="${PORT_HOP_RANGE:-30000-50000}"
            if [[ "$PORT_HOP_RANGE" =~ ^[0-9]+-[0-9]+$ ]]; then
                PORT_START=$(cut -d'-' -f1 <<< "$PORT_HOP_RANGE")
                PORT_END=$(cut -d'-' -f2 <<< "$PORT_HOP_RANGE")
                if [ "$PORT_START" -ge 1 ] && [ "$PORT_END" -le 65535 ] && [ "$PORT_START" -lt "$PORT_END" ]; then
                    PORT_RANGE_COLON="${PORT_START}:${PORT_END}"
                    break
                fi
                echo -e "${RED}错误: 端口范围无效 (必须在 1-65535 之间，且起始端口需小于结束端口)${RESET}"
            else
                echo -e "${RED}错误: 格式不正确，请输入形如 30000-50000 的范围${RESET}"
            fi
        done
    fi
    echo -e "${CYAN}===================================${RESET}"
}

# ================= 真实 IP 探测与域名校验 =================
check_domain_and_ip() {
    echo -e "${CYAN}===== 域名解析校验 =====${RESET}"
    echo -e "${YELLOW}正在穿透 WARP 等虚拟网卡，探测本机物理公网 IPv4...${RESET}"

    DEFAULT_IFACE_V4=$(ip -4 route ls | awk '/default/ && !/wg|warp|tun|tailscale/ {print $5; exit}')
    [ -z "$DEFAULT_IFACE_V4" ] && DEFAULT_IFACE_V4=$(ip -4 route ls | awk '/default/ {print $5; exit}')
    REAL_IPV4=$(curl -s --interface "$DEFAULT_IFACE_V4" -4 https://ipv4.icanhazip.com 2>/dev/null)
    [ -z "$REAL_IPV4" ] && REAL_IPV4=$(curl -s -4 https://ipv4.icanhazip.com 2>/dev/null)

    echo -e "物理网卡 IPv4: ${GREEN}${REAL_IPV4:-探测失败}${RESET}"

    echo -e "${YELLOW}正在通过公共 DNS 请求 $DOMAIN 的 A 记录...${RESET}"
    DOMAIN_IPV4=$(curl -sH "accept: application/dns-json" "https://cloudflare-dns.com/dns-query?name=$DOMAIN&type=A" | grep -oP '(?<="data":")[^"]*' | head -n 1)
    echo -e "域名解析 IPv4 (A 记录): ${GREEN}${DOMAIN_IPV4:-未解析}${RESET}"

    if [ -n "$REAL_IPV4" ] && [ "$REAL_IPV4" == "$DOMAIN_IPV4" ]; then
        echo -e "${GREEN}✓ 域名 A 记录正确指向本机 IPv4。${RESET}"
    else
        echo -e "${RED}✗ 警告: 域名解析的 IPv4 与本机物理 IP 不匹配！${RESET}"
        echo -e "请确保您在域名托管商处正确填写了服务器 IP，且已关闭 Cloudflare 的小黄云代理。"
        read -rp "是否强制继续尝试申请证书？(极大概率失败) [y/N]: " FORCE_CONTINUE
        if [[ ! "$FORCE_CONTINUE" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}已终止安装。请修正 DNS 解析设置后再试。${RESET}"
            exit 1
        fi
    fi
    echo -e "${CYAN}======================================${RESET}"
}

# ================= 端口 80 环境处理 =================
release_port_80() {
    echo -e "${YELLOW}正在检测并释放 80 端口占用情况...${RESET}"

    for svc in nginx apache2 httpd caddy; do
        systemctl stop "$svc" 2>/dev/null || true
    done

    if command -v lsof >/dev/null 2>&1; then
        PORT_80_PIDS=$(lsof -t -i:80 || true)
        [ -n "$PORT_80_PIDS" ] && kill -9 $PORT_80_PIDS 2>/dev/null || true
        sleep 1
    fi

    echo -e "${YELLOW}正在配置防火墙放行 80 端口 (用于 Let's Encrypt 证书验证)...${RESET}"
    command -v ufw >/dev/null 2>&1 && ufw allow 80/tcp >/dev/null 2>&1
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=80/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
    command -v iptables >/dev/null 2>&1 && iptables -I INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1
}

# ================= 证书申请环境准备 =================
prepare_acme_environment() {
    echo -e "${YELLOW}正在构建证书申请防阻断策略 (ACME Hooks)...${RESET}"

    ACME_PRE_HOOK="systemctl stop nginx 2>/dev/null || true; systemctl stop apache2 2>/dev/null || true; systemctl stop httpd 2>/dev/null || true; systemctl stop caddy 2>/dev/null || true;"
    ACME_POST_HOOK="systemctl start nginx 2>/dev/null || true; systemctl start apache2 2>/dev/null || true; systemctl start httpd 2>/dev/null || true; systemctl start caddy 2>/dev/null || true;"

    if command -v warp-cli &> /dev/null && warp-cli status 2>/dev/null | grep -qi "Connected"; then
        echo -e "${YELLOW}检测到官方 WARP 客户端正在运行！已将其纳入自动断开/恢复策略。${RESET}"
        ACME_PRE_HOOK="${ACME_PRE_HOOK} warp-cli disconnect >/dev/null 2>&1;"
        ACME_POST_HOOK="${ACME_POST_HOOK} warp-cli connect >/dev/null 2>&1;"
        warp-cli disconnect >/dev/null 2>&1
        WARP_CLI_TEMP_STOPPED=true
    fi

    if command -v wg-quick &> /dev/null && ip link show wgcf &> /dev/null; then
        echo -e "${YELLOW}检测到 wgcf (WireGuard WARP) 正在运行！已将其纳入自动断开/恢复策略。${RESET}"
        ACME_PRE_HOOK="${ACME_PRE_HOOK} wg-quick down wgcf >/dev/null 2>&1;"
        ACME_POST_HOOK="${ACME_POST_HOOK} wg-quick up wgcf >/dev/null 2>&1;"
        wg-quick down wgcf >/dev/null 2>&1
        WGCF_TEMP_STOPPED=true
    fi

    eval "$ACME_PRE_HOOK"
    release_port_80
}

restore_warp_if_needed() {
    [ "$WARP_CLI_TEMP_STOPPED" = true ] && warp-cli connect >/dev/null 2>&1
    [ "$WGCF_TEMP_STOPPED" = true ] && wg-quick up wgcf >/dev/null 2>&1
    return 0
}

# ================= 内核网络参数优化 (面向高延迟/高带宽链路) =================
tune_kernel_network() {
    echo -e "${YELLOW}正在优化内核网络参数以提升单连接吞吐...${RESET}"

    if [ ! -w /proc/sys/net ]; then
        echo -e "${YELLOW}当前环境不支持写入 /proc/sys/net (可能为容器)，跳过内核调优。${RESET}"
        return
    fi

    cat > /etc/sysctl.d/99-hysteria2-tuning.conf << 'EOF'
# Hysteria2 / QUIC 链路优化
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.ipv4.udp_mem = 1048576 4194304 33554432
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    sysctl --system >/dev/null 2>&1
    echo -e "${GREEN}✓ 内核网络参数已优化 (UDP 缓冲区扩容 + fq/BBR)${RESET}"
}

# ================= 核心安装与配置生成 =================
install_hysteria2() {
    if [ -f "$NODE_INFO_FILE" ]; then
        echo -e "${YELLOW}检测到已存在的 Hysteria2 安装。${RESET}"
        read -rp "是否覆盖重新安装？[y/N]: " REINSTALL
        [[ ! "$REINSTALL" =~ ^[Yy]$ ]] && { echo "已取消。"; return; }
    fi

    get_user_input
    echo "开始安装依赖包..."
    install_packages
    echo "生成随机密码..."
    generate_password
    echo "获取端口配置..."
    get_port
    check_domain_and_ip

    echo "下载并安装 Hysteria2 官方核心..."
    if ! bash <(curl -fsSL https://get.hy2.sh/); then
        echo "错误: Hysteria2 安装失败"
        exit 1
    fi

    echo "部署 acme.sh 证书管理工具..."
    if [ ! -f "/root/.acme.sh/acme.sh" ]; then
        curl https://get.acme.sh | sh -s email="$EMAIL"
    fi

    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    /root/.acme.sh/acme.sh --register-account -m "$EMAIL" --server letsencrypt >/dev/null 2>&1

    prepare_acme_environment

    echo "为 $DOMAIN 申请 TLS 证书..."
    if ! /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256 \
        --pre-hook "$ACME_PRE_HOOK" \
        --post-hook "$ACME_POST_HOOK"; then
        echo -e "${RED}错误: 证书申请失败。请确认 80 端口完全开放且域名解析状态正确无代理。${RESET}"
        restore_warp_if_needed
        exit 1
    fi

    mkdir -p "$HY_DIR"
    /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
        --key-file "${HY_DIR}/server.key" \
        --fullchain-file "${HY_DIR}/server.crt" \
        --reloadcmd "systemctl restart hysteria-server"

    restore_warp_if_needed

    id hysteria &> /dev/null && chown -R hysteria:hysteria "$HY_DIR"
    chmod 600 "${HY_DIR}/server.key"
    chmod 644 "${HY_DIR}/server.crt"

    tune_kernel_network

    echo "创建 Hysteria2 服务端配置文件..."
    cat > "${HY_DIR}/config.yaml" << EOF
listen: :$SERVER_PORT

tls:
  cert: ${HY_DIR}/server.crt
  key: ${HY_DIR}/server.key

auth:
  type: password
  password: $HYSTERIA_PASSWORD

masquerade:
  type: proxy
  proxy:
    url: $MASQUERADE_URL
    rewriteHost: true

quic:
  initStreamReceiveWindow: 33554432
  maxStreamReceiveWindow: 33554432
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
EOF

    echo "启动 Hysteria2 服务及配置网络规则..."
    if check_systemd; then
        systemctl daemon-reload
        systemctl enable hysteria-server.service
        systemctl restart hysteria-server.service

        if [[ "$ENABLE_PORT_HOP" =~ ^[Yy]$ ]]; then
            echo "加载并持久化端口跳跃 (iptables) 规则..."
            IPTABLES_PATH=$(command -v iptables)
            cat > /etc/systemd/system/hysteria-porthop.service << EOF
[Unit]
Description=Hysteria 2 Port Hopping iptables rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${IPTABLES_PATH} -t nat -A PREROUTING -p udp --dport ${PORT_RANGE_COLON} -j REDIRECT --to-ports ${SERVER_PORT}
ExecStop=${IPTABLES_PATH} -t nat -D PREROUTING -p udp --dport ${PORT_RANGE_COLON} -j REDIRECT --to-ports ${SERVER_PORT}

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable hysteria-porthop.service
            systemctl restart hysteria-porthop.service
            HOP_STATUS="已启用 (跳跃范围: ${PORT_HOP_RANGE} -> 主端口: ${SERVER_PORT})"
        else
            HOP_STATUS="未启用"
        fi
        sleep 2
    else
        echo "请手动启动 Hysteria2 服务"
        HOP_STATUS="未启用 (不支持 Systemd)"
    fi

    # 持久化节点信息，供后续"查看节点信息"菜单使用
    cat > "$NODE_INFO_FILE" << EOF
DOMAIN="$DOMAIN"
SERVER_PORT="$SERVER_PORT"
HYSTERIA_PASSWORD="$HYSTERIA_PASSWORD"
MASQUERADE_URL="$MASQUERADE_URL"
ENABLE_PORT_HOP="$ENABLE_PORT_HOP"
PORT_HOP_RANGE="$PORT_HOP_RANGE"
HOP_STATUS="$HOP_STATUS"
EOF

    show_client_config
    check_service_status
}

# ================= 状态检查与信息输出 =================
check_service_status() {
    echo -e "${CYAN}===== 服务状态 =====${RESET}"
    if check_systemd; then
        if systemctl is-active --quiet hysteria-server.service; then
            echo -e "${GREEN}✓ Hysteria2 主服务运行正常${RESET}"
        else
            echo -e "${RED}✗ Hysteria2 主服务未运行，请执行 journalctl -u hysteria-server -e 查看日志${RESET}"
        fi
        if [[ "$ENABLE_PORT_HOP" =~ ^[Yy]$ ]]; then
            if systemctl is-active --quiet hysteria-porthop.service; then
                echo -e "${GREEN}✓ Hysteria2 端口跳跃防火墙规则已成功加载${RESET}"
            else
                echo -e "${RED}✗ Hysteria2 端口跳跃防火墙规则加载失败${RESET}"
            fi
        fi
    fi
    echo -e "${CYAN}===================${RESET}"
}

show_client_config() {
    local mport_param=""
    [[ "$ENABLE_PORT_HOP" =~ ^[Yy]$ ]] && mport_param="&mport=${PORT_HOP_RANGE}"

    local connection_link="${HYSTERIA_PASSWORD}@${DOMAIN}:${SERVER_PORT}/?sni=${DOMAIN}${mport_param}#${DOMAIN}"

    echo
    echo -e "${GREEN}===== Hysteria2 节点信息 =====${RESET}"
    echo
    echo -e "${CYAN}=========== 配置参数 =============${RESET}"
    echo -e "服务器域名 (SNI): ${YELLOW}${DOMAIN}${RESET}"
    echo -e "主监听端口      : ${YELLOW}${SERVER_PORT}${RESET}"
    echo -e "端口跳跃状态    : ${YELLOW}${HOP_STATUS}${RESET}"
    echo -e "密码            : ${YELLOW}${HYSTERIA_PASSWORD}${RESET}"
    echo -e "服务端伪装站    : ${YELLOW}${MASQUERADE_URL}${RESET}"
    echo -e "${CYAN}==================================${RESET}"
    echo
    echo -e "${CYAN}连接链接 (URI 格式 - 支持直接复制或导入):${RESET}"
    echo -e "${GREEN}hysteria2://${connection_link}${RESET}"
    echo
}

view_node_info() {
    if [ ! -f "$NODE_INFO_FILE" ]; then
        echo -e "${RED}未检测到已安装的节点，请先执行安装。${RESET}"
        return
    fi
    # shellcheck source=/dev/null
    source "$NODE_INFO_FILE"
    show_client_config
    check_service_status
}

restart_service() {
    if ! check_systemd; then
        echo -e "${RED}当前系统不支持 systemd，无法自动重启，请手动操作。${RESET}"
        return
    fi
    if [ ! -f "${HY_DIR}/config.yaml" ]; then
        echo -e "${RED}未检测到已安装的节点，请先执行安装。${RESET}"
        return
    fi
    systemctl restart hysteria-server.service
    [ -f /etc/systemd/system/hysteria-porthop.service ] && systemctl restart hysteria-porthop.service
    sleep 1
    echo -e "${GREEN}✓ 已重启 Hysteria2 服务${RESET}"
    check_service_status
}

# ================= 彻底卸载与环境清理 =================
uninstall_hysteria2() {
    echo -e "${YELLOW}开始执行 Hysteria2 彻底卸载与系统还原程序...${RESET}"

    if check_systemd; then
        if [ -f /etc/systemd/system/hysteria-porthop.service ]; then
            echo -e "${YELLOW}正在清理 iptables 端口转发防火墙规则...${RESET}"
            systemctl stop hysteria-porthop.service 2>/dev/null || true
            systemctl disable hysteria-porthop.service 2>/dev/null || true
            rm -f /etc/systemd/system/hysteria-porthop.service
        fi

        systemctl stop hysteria-server.service 2>/dev/null || true
        systemctl disable hysteria-server.service 2>/dev/null || true
        rm -f /etc/systemd/system/hysteria-server.service
        systemctl daemon-reload
    fi

    pgrep -f hysteria &> /dev/null && pkill -f hysteria

    rm -f /usr/local/bin/hysteria
    rm -rf "$HY_DIR"
    rm -f /etc/sysctl.d/99-hysteria2-tuning.conf

    echo -e "${YELLOW}正在清理 acme.sh 证书环境与自动续期任务...${RESET}"
    if [ -f "/root/.acme.sh/acme.sh" ]; then
        /root/.acme.sh/acme.sh --uninstall >/dev/null 2>&1
        rm -rf /root/.acme.sh
    fi

    rm -f "$(readlink -f "$0")"

    echo -e "${GREEN}======================================================${RESET}"
    echo -e "${GREEN} 卸载完成！Hysteria 2、防火墙规则、配置文件、证书及定时任务已完全清除，系统已恢复至初始状态。${RESET}"
    echo -e "${GREEN}======================================================${RESET}"
    exit 0
}

# ================= 主控制菜单 =================
show_menu() {
    clear
    echo -e "${GREEN}======================================================${RESET}"
    echo -e "${GREEN}          Hysteria 2 自动化部署与管理脚本            ${RESET}"
    echo -e "${GREEN}======================================================${RESET}"
    echo -e "${CYAN} 1.${RESET} 安装 Hysteria 2"
    echo -e "${CYAN} 2.${RESET} 查看节点信息 / 服务状态"
    echo -e "${CYAN} 3.${RESET} 重启 Hysteria 2 服务"
    echo -e "${CYAN} 4.${RESET} 彻底卸载 Hysteria 2 (彻底清理规则与环境)"
    echo -e "${CYAN} 0.${RESET} 退出脚本"
    echo -e "${GREEN}======================================================${RESET}"
    echo ""

    read -rp "请输入对应的数字以选择功能: " choice

    case $choice in
        1) install_hysteria2 ;;
        2) view_node_info ;;
        3) restart_service ;;
        4)
            read -rp "您确定要彻底卸载 Hysteria 2、清理防火墙规则并删除此脚本自身吗？[y/N]: " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                uninstall_hysteria2
            else
                echo -e "${YELLOW}已取消卸载操作。${RESET}"
            fi
            ;;
        0) echo "已退出脚本。"; exit 0 ;;
        *)
            echo -e "${RED}输入错误，请输入有效的数字选项。${RESET}"
            sleep 2
            ;;
    esac
    read -rp "按回车键返回主菜单..." _
    show_menu
}

show_menu
