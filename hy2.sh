#!/bin/bash
# Hysteria2 Automated Installation & Management Script (IPv4 完善防断流版)
# 特性: 端口跳跃 / NAT 防断流调优 / 强制 IPv4 / 彻底无痕卸载

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

if [[ $EUID -ne 0 ]]; then
    clear
    echo -e "${RED}错误: 此脚本必须以 root 权限运行!${RESET}" 1>&2
    exit 1
fi

# ================= 基础环境检测与配置获取 =================
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DETECTED_OS=$NAME
        OS_VERSION=$VERSION_ID
    elif type lsb_release >/dev/null 2>&1; then
        DETECTED_OS=$(lsb_release -si)
        OS_VERSION=$(lsb_release -sr)
    elif [ -f /etc/lsb-release ]; then
        . /etc/lsb-release
        DETECTED_OS=$DISTRIB_ID
        OS_VERSION=$DISTRIB_RELEASE
    elif [ -f /etc/debian_version ]; then
        DETECTED_OS=Debian
        OS_VERSION=$(cat /etc/debian_version)
    elif [ -f /etc/SuSe-release ]; then
        DETECTED_OS=openSUSE
    elif [ -f /etc/redhat-release ]; then
        DETECTED_OS=$(cat /etc/redhat-release | awk '{print $1}')
    else
        DETECTED_OS=$(uname -s)
        OS_VERSION=$(uname -r)
    fi
}

get_user_input() {
    echo -e "${CYAN}===== 基础配置信息获取 =====${RESET}"

    while true; do
        read -p "请输入您已解析至本机的真实域名 (必须包含 '.', 用于申请证书与 SNI): " DOMAIN
        if [ -n "$DOMAIN" ]; then
            break
        else
            echo -e "${RED}错误: 域名不能为空，请重新输入。${RESET}"
        fi
    done

    while true; do
        read -p "请输入您的合法邮箱 (用于接收证书到期通知，例如 admin@example.com): " EMAIL
        if [[ -n "$EMAIL" && "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            break
        else
            echo -e "${RED}错误: 邮箱格式不合法，请重新输入标准的邮箱地址。${RESET}"
        fi
    done

    echo -e "${CYAN}===== 伪装站点设置 =====${RESET}"
    echo "说明: 当防火墙或审查者主动探测您的节点时，服务端将向其展示该网站的内容。"
    read -p "请输入防主动探测的伪装网站 URL (默认: https://www.tesla.com): " MASQUERADE_URL

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
        apt-get install -y curl wget openssl gawk ca-certificates socat lsof iptables iproute2 cron
    elif command -v yum &> /dev/null; then
        yum update -y
        yum install -y epel-release
        yum install -y curl wget openssl gawk ca-certificates socat lsof iptables iproute cronie
    elif command -v dnf &> /dev/null; then
        dnf update -y
        dnf install -y curl wget openssl gawk ca-certificates socat lsof iptables iproute cronie
    elif command -v zypper &> /dev/null; then
        zypper refresh
        zypper install -y curl wget openssl gawk ca-certificates socat lsof iptables iproute2 cron
    elif command -v pacman &> /dev/null; then
        pacman -Syu --noconfirm
        pacman -S --noconfirm curl wget openssl gawk ca-certificates socat lsof iptables iproute2 cronie
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
    if ! command -v systemctl &> /dev/null; then
        return 1
    fi
    return 0
}

generate_password() {
    if [ -f /proc/sys/kernel/random/uuid ]; then
        HYSTERIA_PASSWORD=$(cat /proc/sys/kernel/random/uuid | sed 's/-//g' | head -c 16)
    else
        HYSTERIA_PASSWORD=$(openssl rand -hex 8)
    fi
}

get_port() {
    read -t 15 -p "回车或等待15秒为随机主端口，或者自定义主监听端口请输入(1-65535): " SERVER_PORT
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
    read -p "是否启用端口跳跃功能? [y/N]: " ENABLE_PORT_HOP
    if [[ "$ENABLE_PORT_HOP" =~ ^[Yy]$ ]]; then
        while true; do
            read -p "请输入端口跳跃的范围 (直接回车默认 30000-50000): " PORT_HOP_RANGE
            if [ -z "$PORT_HOP_RANGE" ]; then
                PORT_HOP_RANGE="30000-50000"
            fi
            if [[ "$PORT_HOP_RANGE" =~ ^[0-9]+-[0-9]+$ ]]; then
                PORT_START=$(echo "$PORT_HOP_RANGE" | cut -d'-' -f1)
                PORT_END=$(echo "$PORT_HOP_RANGE" | cut -d'-' -f2)
                if [ "$PORT_START" -ge 1 ] && [ "$PORT_END" -le 65535 ] && [ "$PORT_START" -lt "$PORT_END" ]; then
                    PORT_RANGE_COLON="${PORT_START}:${PORT_END}"
                    break
                else
                    echo -e "${RED}错误: 端口范围无效 (必须在 1-65535 之间，且起始端口需小于结束端口)${RESET}"
                fi
            else
                echo -e "${RED}错误: 格式不正确，请输入形如 30000-50000 的范围${RESET}"
            fi
        done
    fi
    echo -e "${CYAN}===================================${RESET}"
}

# ================= 真实 IP 探测与域名校验 =================
check_domain_and_ip() {
    echo -e "${CYAN}===== 网络环境与真实 IP 强制检测 =====${RESET}"
    echo -e "${YELLOW}正在穿透虚拟网卡，探测本机物理公网 IPv4...${RESET}"

    DEFAULT_IFACE=$(ip -4 route ls | awk '/default/ && !/wg|warp|tun|tailscale/ {print $5; exit}')
    if [ -z "$DEFAULT_IFACE" ]; then DEFAULT_IFACE=$(ip -4 route ls | awk '/default/ {print $5; exit}'); fi
    REAL_IPV4=$(curl -s --interface "$DEFAULT_IFACE" -4 https://ipv4.icanhazip.com 2>/dev/null)
    if [ -z "$REAL_IPV4" ]; then REAL_IPV4=$(curl -s -4 https://ipv4.icanhazip.com 2>/dev/null); fi

    echo -e "物理网卡 IPv4: ${GREEN}${REAL_IPV4:-未分配}${RESET}"
    echo -e "${YELLOW}正在通过公共 DNS 请求 $DOMAIN 的解析记录...${RESET}"

    DOMAIN_IPV4=$(curl -sH "accept: application/dns-json" "https://cloudflare-dns.com/dns-query?name=$DOMAIN&type=A" | grep -oP '(?<="data":")[^"]*' | grep -E "^([0-9]{1,3}\.){3}[0-9]{1,3}$" | head -n 1)
    DOMAIN_IPV6=$(curl -sH "accept: application/dns-json" "https://cloudflare-dns.com/dns-query?name=$DOMAIN&type=AAAA" | grep -oP '(?<="data":")[^"]*' | grep -E "^[0-9a-fA-F:]+$" | head -n 1)

    echo -e "域名解析 IPv4: ${GREEN}${DOMAIN_IPV4:-未解析}${RESET}"

    if [ -n "$DOMAIN_IPV6" ]; then
        echo -e "${RED}========================================================================${RESET}"
        echo -e "${RED} 严重警告: 您的域名仍然配置了真实的 AAAA (IPv6) 解析记录: ${DOMAIN_IPV6} ${RESET}"
        echo -e "${RED} 因为您的 VPS 是纯 IPv4 环境，该记录必定导致证书申请超时，客户端也无法连接！${RESET}"
        echo -e "${RED} 请务必前往域名托管商删除所有 AAAA 记录，等待1-2分钟后再试。${RESET}"
        echo -e "${RED}========================================================================${RESET}"
        exit 1
    fi

    if [ -n "$REAL_IPV4" ] && [ "$REAL_IPV4" == "$DOMAIN_IPV4" ]; then
        echo -e "${GREEN}✓ 域名解析强制校验通过！记录正确指向了本机的原生 IPv4。${RESET}"
    else
        echo -e "${RED}✗ 警告: 域名解析的 IP 与本机原生物理 IP 不匹配！${RESET}"
        read -p "是否强制继续尝试申请证书？(极大概率失败) [y/N]: " FORCE_CONTINUE
        if [[ ! "$FORCE_CONTINUE" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}已终止安装。请修正 DNS 解析设置后再试。${RESET}"
            exit 1
        fi
    fi
    echo -e "${CYAN}======================================${RESET}"
}

# ================= 防火墙放行与内核防断流优化 =================
config_firewall_and_nat() {
    echo -e "${YELLOW}正在检测并释放 80 端口占用情况...${RESET}"
    systemctl stop nginx 2>/dev/null || true
    systemctl stop apache2 2>/dev/null || true
    systemctl stop httpd 2>/dev/null || true
    systemctl stop caddy 2>/dev/null || true

    if command -v lsof >/dev/null 2>&1; then
        PORT_80_PIDS=$(lsof -t -i:80 || true)
        if [ -n "$PORT_80_PIDS" ]; then
            for pid in $PORT_80_PIDS; do
                kill -9 "$pid" 2>/dev/null || true
            done
            sleep 2
        fi
    fi

    echo -e "${YELLOW}正在配置系统防火墙放行 80 端口及 Hysteria UDP 端口...${RESET}"
    if command -v ufw >/dev/null 2>&1; then
        ufw allow 80/tcp >/dev/null 2>&1
        ufw allow ${SERVER_PORT}/udp >/dev/null 2>&1
        if [[ "$ENABLE_PORT_HOP" =~ ^[Yy]$ ]]; then
            ufw allow ${PORT_RANGE_COLON}/udp >/dev/null 2>&1
        fi
    fi
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=80/tcp >/dev/null 2>&1
        firewall-cmd --permanent --add-port=${SERVER_PORT}/udp >/dev/null 2>&1
        if [[ "$ENABLE_PORT_HOP" =~ ^[Yy]$ ]]; then
            firewall-cmd --permanent --add-port=${PORT_HOP_RANGE}/udp >/dev/null 2>&1
        fi
        firewall-cmd --reload >/dev/null 2>&1
    fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1
        iptables -I INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT >/dev/null 2>&1
        if [[ "$ENABLE_PORT_HOP" =~ ^[Yy]$ ]]; then
            iptables -I INPUT -p udp --dport ${PORT_RANGE_COLON} -j ACCEPT >/dev/null 2>&1
        fi
    fi

    # 专门针对端口跳跃特性的 NAT 连接跟踪表优化（防断流核心）
    if [[ "$ENABLE_PORT_HOP" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}正在优化内核 NAT 连接跟踪表 (防断流与防溢出机制)...${RESET}"
        cat > /etc/sysctl.d/99-hysteria-nat.conf << EOF
net.netfilter.nf_conntrack_max = 2097152
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180
EOF
        modprobe nf_conntrack 2>/dev/null || true
        sysctl --system >/dev/null 2>&1
    fi
}

# ================= 核心安装与配置生成 =================
install_hysteria2() {
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

    ACME_PRE_HOOK="systemctl stop nginx 2>/dev/null || true; systemctl stop apache2 2>/dev/null || true; systemctl stop httpd 2>/dev/null || true; systemctl stop caddy 2>/dev/null || true;"
    ACME_POST_HOOK="systemctl start nginx 2>/dev/null || true; systemctl start apache2 2>/dev/null || true; systemctl start httpd 2>/dev/null || true; systemctl start caddy 2>/dev/null || true;"

    eval "$ACME_PRE_HOOK"
    config_firewall_and_nat

    echo "为 $DOMAIN 申请 TLS 证书 (强制开启 IPv4 监听模式)..."
    if ! /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --listen-v4 -k ec-256 \
        --pre-hook "$ACME_PRE_HOOK" \
        --post-hook "$ACME_POST_HOOK"; then
        echo -e "${RED}错误: 证书申请失败。请确认 80 端口完全开放且云服务商(控制台)防火墙未阻拦。${RESET}"
        exit 1
    fi

    mkdir -p /etc/hysteria/
    /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
        --key-file /etc/hysteria/server.key \
        --fullchain-file /etc/hysteria/server.crt \
        --reloadcmd "systemctl restart hysteria-server"

    if id hysteria &> /dev/null; then
        chown -R hysteria:hysteria /etc/hysteria
    fi
    chmod 600 /etc/hysteria/server.key
    chmod 644 /etc/hysteria/server.crt

    STREAM_RW=$(awk -v min=16777216 -v max=33554432 'BEGIN{srand(); print int(min+rand()*(max-min+1))}')
    CONN_RW=$(awk -v min=33554432 -v max=83886080 'BEGIN{srand(); print int(min+rand()*(max-min+1))}')

    echo "创建 Hysteria2 服务端配置文件..."
    cat > /etc/hysteria/config.yaml << EOF
listen: :$SERVER_PORT

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: $HYSTERIA_PASSWORD

masquerade:
  type: proxy
  proxy:
    url: $MASQUERADE_URL
    rewriteHost: true

quic:
  initStreamReceiveWindow: $STREAM_RW
  maxStreamReceiveWindow: $STREAM_RW
  initConnReceiveWindow: $CONN_RW
  maxConnReceiveWindow: $CONN_RW
EOF

    # 保存关键配置信息以便卸载时精准清理网络规则
    cat > /etc/hysteria/.install_info << EOF
DOMAIN=$DOMAIN
SERVER_PORT=$SERVER_PORT
ENABLE_PORT_HOP=$ENABLE_PORT_HOP
PORT_HOP_RANGE=$PORT_HOP_RANGE
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

    show_client_config
    check_service_status
}

# ================= 状态检查与信息输出 =================
check_service_status() {
    echo -e "${CYAN}===== 服务状态 =====${RESET}"
    if command -v systemctl &> /dev/null; then
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
    if [[ "$ENABLE_PORT_HOP" =~ ^[Yy]$ ]]; then
        local MPORT_PARAM="&mport=${PORT_HOP_RANGE}"
    else
        local MPORT_PARAM=""
    fi

    local connection_link="${HYSTERIA_PASSWORD}@${DOMAIN}:${SERVER_PORT}/?sni=${DOMAIN}${MPORT_PARAM}#${DOMAIN}"

    echo
    echo -e "${GREEN}===== Hysteria2 安装与配置完成 =====${RESET}"
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

# ================= 彻底卸载与环境清理 =================
uninstall_hysteria2() {
    echo -e "${YELLOW}开始执行 Hysteria2 彻底无痕卸载程序...${RESET}"

    if [ -f /etc/hysteria/.install_info ]; then
        # shellcheck disable=SC1091
        source /etc/hysteria/.install_info
    fi

    if command -v systemctl &> /dev/null; then
        if [ -f /etc/systemd/system/hysteria-porthop.service ]; then
            echo -e "${YELLOW}正在清理 iptables 端口转发网络规则...${RESET}"
            systemctl stop hysteria-porthop.service 2>/dev/null || true
            systemctl disable hysteria-porthop.service 2>/dev/null || true
            rm -f /etc/systemd/system/hysteria-porthop.service
        fi

        if [ -n "$PORT_HOP_RANGE" ] && [ -n "$SERVER_PORT" ]; then
            PORT_START=$(echo "$PORT_HOP_RANGE" | cut -d'-' -f1)
            PORT_END=$(echo "$PORT_HOP_RANGE" | cut -d'-' -f2)
            if [ -n "$PORT_START" ] && [ -n "$PORT_END" ]; then
                iptables -t nat -D PREROUTING -p udp --dport "${PORT_START}:${PORT_END}" -j REDIRECT --to-ports "${SERVER_PORT}" 2>/dev/null || true
            fi
        fi

        echo -e "${YELLOW}正在中止 Hysteria2 系统级守护进程...${RESET}"
        systemctl stop hysteria-server.service 2>/dev/null || true
        systemctl disable hysteria-server.service 2>/dev/null || true
        rm -f /etc/systemd/system/hysteria-server.service
        rm -f /etc/systemd/system/hysteria-server@.service
        systemctl daemon-reload
        systemctl reset-failed 2>/dev/null || true
    fi

    if pgrep -f hysteria &> /dev/null; then
        pkill -9 -f hysteria
    fi

    if command -v curl &> /dev/null; then
        bash <(curl -fsSL https://get.hy2.sh/) --remove 2>/dev/null || true
    fi

    echo -e "${YELLOW}正在清理内核防断流调优配置...${RESET}"
    rm -f /etc/sysctl.d/99-hysteria-nat.conf
    sysctl --system >/dev/null 2>&1 || true

    echo -e "${YELLOW}正在物理销毁配置文件、二进制核心与证书存放目录...${RESET}"
    rm -f /usr/local/bin/hysteria
    rm -rf /etc/hysteria
    rm -rf /usr/local/etc/hysteria
    rm -rf /var/log/hysteria

    echo -e "${YELLOW}正在清理 acme.sh 证书环境与计划续期任务...${RESET}"
    if [ -f "/root/.acme.sh/acme.sh" ]; then
        /root/.acme.sh/acme.sh --uninstall >/dev/null 2>&1
    fi
    rm -rf /root/.acme.sh
    if command -v crontab &> /dev/null; then
        crontab -l 2>/dev/null | grep -v 'acme.sh' | crontab - 2>/dev/null || true
    fi

    echo -e "${YELLOW}正在清理服务运行日志...${RESET}"
    if command -v journalctl &> /dev/null; then
        journalctl --rotate >/dev/null 2>&1 || true
        journalctl --vacuum-time=1s -u hysteria-server >/dev/null 2>&1 || true
    fi

    SCRIPT_PATH=$(readlink -f "$0")
    rm -f "$SCRIPT_PATH"

    echo -e "${GREEN}======================================================${RESET}"
    echo -e "${GREEN} 卸载完成！Hysteria 2 核心、配置信息、防断流设置、证书及端口跳跃规则已清除。${RESET}"
    echo -e "${GREEN}======================================================${RESET}"
    exit 0
}

# ================= 主控制菜单 =================
show_menu() {
    clear
    echo -e "${GREEN}======================================================${RESET}"
    echo -e "${GREEN}      Hysteria 2 自动化部署与管理脚本 (完善防断流版)        ${RESET}"
    echo -e "${GREEN}======================================================${RESET}"
    echo -e "${CYAN} 1.${RESET} 安装 Hysteria 2 (端口跳跃防 QoS / NAT 深度防断流优化)"
    echo -e "${CYAN} 2.${RESET} 彻底无痕卸载 Hysteria 2"
    echo -e "${CYAN} 0.${RESET} 退出脚本"
    echo -e "${GREEN}======================================================${RESET}"
    echo ""

    read -p "请输入对应的数字以选择功能: " choice

    case $choice in
        1)
            install_hysteria2
            ;;
        2)
            read -p "您确定要彻底卸载 Hysteria 2、清理网络规则并删除此脚本自身吗？[y/N]: " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                uninstall_hysteria2
            else
                echo -e "${YELLOW}已取消卸载操作。${RESET}"
            fi
            ;;
        0)
            echo "已退出脚本。"
            exit 0
            ;;
        *)
            echo -e "${RED}输入错误，请输入有效的数字选项。${RESET}"
            sleep 2
            show_menu
            ;;
    esac
}

show_menu
