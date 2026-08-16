#!/bin/bash
# Hysteria2 Installation Script (Let's Encrypt Edition)
# Author: https://1024.day

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

if [[ $EUID -ne 0 ]]; then
    clear
    echo -e "${RED}Error: This script must be run as root!${RESET}" 1>&2
    exit 1
fi

# 检测操作系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DETECTED_OS=$NAME
        OS_VERSION=$VERSION_ID
    elif type lsb_release >/dev/null 2>&1; then
        DETECTED_OS=$(lsb_release -si)
        OS_VERSION=$(lsb_release -sr)
    elif [ -f /etc/debian_version ]; then
        DETECTED_OS=Debian
        OS_VERSION=$(cat /etc/debian_version)
    elif [ -f /etc/redhat-release ]; then
        DETECTED_OS=$(awk '{print $1}' /etc/redhat-release)
    else
        DETECTED_OS=$(uname -s)
        OS_VERSION=$(uname -r)
    fi
}

# 安装必要的包 (新增 socat/lsof，acme.sh standalone 模式签发证书需要)
install_packages() {
    detect_os
    echo "检测到操作系统: $DETECTED_OS $OS_VERSION"

    if command -v apt-get &> /dev/null; then
        echo "使用 APT 包管理器..."
        apt-get update -y
        apt-get install -y curl wget openssl gawk ca-certificates socat lsof
    elif command -v dnf &> /dev/null; then
        echo "使用 DNF 包管理器..."
        dnf install -y curl wget openssl gawk ca-certificates socat lsof
    elif command -v yum &> /dev/null; then
        echo "使用 YUM 包管理器..."
        yum install -y epel-release
        yum install -y curl wget openssl gawk ca-certificates socat lsof
    elif command -v pacman &> /dev/null; then
        echo "使用 Pacman 包管理器..."
        pacman -Sy --noconfirm curl wget openssl gawk ca-certificates socat lsof
    else
        echo "错误: 未找到支持的包管理器!"
        echo "请手动安装以下依赖: curl wget openssl gawk ca-certificates socat lsof"
        exit 1
    fi
}

check_systemd() {
    if ! command -v systemctl &> /dev/null; then
        echo "警告: systemctl 未找到，可能不支持 systemd"
        echo "请手动管理 hysteria 服务"
        return 1
    fi
    return 0
}

generate_password() {
    if [ -f /proc/sys/kernel/random/uuid ]; then
        HYSTERIA_PASSWORD=$(cat /proc/sys/kernel/random/uuid)
    else
        HYSTERIA_PASSWORD=$(openssl rand -hex 16)
    fi
}

get_port() {
    read -t 15 -p "回车或等待15秒为随机端口，或者自定义端口请输入(1-65535): " SERVER_PORT
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
}

# 真实域名 + 邮箱 (申请 Let's Encrypt 证书必需)
get_domain_and_email() {
    while true; do
        read -p "请输入已解析至本机的真实域名 (用于申请证书与 SNI): " DOMAIN
        [ -n "$DOMAIN" ] && break
        echo -e "${RED}错误: 域名不能为空。${RESET}"
    done
    while true; do
        read -p "请输入用于接收证书到期提醒的邮箱: " EMAIL
        [[ "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] && break
        echo -e "${RED}错误: 邮箱格式不合法。${RESET}"
    done
}

# 伪装站点 (被主动探测时展示的内容，与证书域名无关，不需要真实解析)
get_masquerade_url() {
    read -p "请输入防探测伪装网站 URL (默认: https://www.tesla.com): " MASQUERADE_URL
    if [ -z "$MASQUERADE_URL" ]; then
        MASQUERADE_URL="https://www.tesla.com"
    elif [[ ! "$MASQUERADE_URL" =~ ^https?:// ]]; then
        MASQUERADE_URL="https://${MASQUERADE_URL}"
    fi
}

get_server_ip() {
    local server_ip
    server_ip=$(curl -s -4 --connect-timeout 10 http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | awk -F "[=]" '{print $2}')
    [[ -z "${server_ip}" ]] && server_ip=$(curl -s -6 --connect-timeout 10 http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | awk -F "[=]" '{print $2}')
    [[ -z "${server_ip}" ]] && server_ip=$(curl -s --connect-timeout 10 ifconfig.me)
    [[ -z "${server_ip}" ]] && server_ip=$(curl -s --connect-timeout 10 ipinfo.io/ip)
    if [[ -z "${server_ip}" ]]; then
        echo "错误: 无法获取服务器IP地址" >&2
        exit 1
    fi
    echo "${server_ip}"
}

# 校验域名解析是否指向本机，避免签证时才发现解析错误
check_domain_resolution() {
    echo -e "${YELLOW}正在校验域名解析...${RESET}"
    local server_ip domain_ip
    server_ip=$(get_server_ip)
    domain_ip=$(curl -sH "accept: application/dns-json" "https://cloudflare-dns.com/dns-query?name=${DOMAIN}&type=A" | grep -oP '(?<="data":")[^"]*' | head -n 1)

    echo -e "本机公网 IP  : ${GREEN}${server_ip:-探测失败}${RESET}"
    echo -e "域名解析 IP  : ${GREEN}${domain_ip:-未解析}${RESET}"

    if [ "$server_ip" == "$domain_ip" ]; then
        echo -e "${GREEN}✓ 域名解析正确指向本机。${RESET}"
    else
        echo -e "${RED}✗ 警告: 域名解析与本机 IP 不一致，证书申请大概率会失败。${RESET}"
        echo -e "请确认 DNS 记录已生效，且未开启 Cloudflare 代理(小黄云)。"
        read -p "是否仍然继续？[y/N]: " FORCE_CONTINUE
        [[ ! "$FORCE_CONTINUE" =~ ^[Yy]$ ]] && { echo "已终止安装。"; exit 1; }
    fi
}

# 释放 80 端口，acme.sh standalone 模式验证需要独占使用
release_port_80() {
    echo "正在释放 80 端口..."
    for svc in nginx apache2 httpd caddy; do
        systemctl stop "$svc" 2>/dev/null || true
    done
    if command -v lsof >/dev/null 2>&1; then
        local pids
        pids=$(lsof -t -i:80 2>/dev/null || true)
        [ -n "$pids" ] && kill -9 $pids 2>/dev/null || true
    fi
    command -v ufw >/dev/null 2>&1 && ufw allow 80/tcp >/dev/null 2>&1
    command -v firewall-cmd >/dev/null 2>&1 && { firewall-cmd --permanent --add-port=80/tcp >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; }
    command -v iptables >/dev/null 2>&1 && iptables -I INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1
}

# 自动申请并安装 Let's Encrypt 证书
issue_letsencrypt_cert() {
    echo "正在部署 acme.sh 证书管理工具..."
    if [ ! -f "/root/.acme.sh/acme.sh" ]; then
        curl -s https://get.acme.sh | sh -s email="$EMAIL"
    fi
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    /root/.acme.sh/acme.sh --register-account -m "$EMAIL" --server letsencrypt >/dev/null 2>&1

    release_port_80

    echo "正在为 ${DOMAIN} 申请证书..."
    if ! /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256; then
        echo -e "${RED}错误: 证书申请失败，请检查 80 端口是否开放、域名解析是否正确。${RESET}"
        exit 1
    fi

    mkdir -p /etc/hysteria/
    /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
        --key-file /etc/hysteria/server.key \
        --fullchain-file /etc/hysteria/server.crt \
        --reloadcmd "systemctl restart hysteria-server"

    if id hysteria &> /dev/null; then
        chown hysteria:hysteria /etc/hysteria/server.key /etc/hysteria/server.crt
    fi
    chmod 600 /etc/hysteria/server.key
    chmod 644 /etc/hysteria/server.crt
    echo -e "${GREEN}✓ 证书已签发并安装，acme.sh 会自动续期，无需手动维护${RESET}"
}

# 安装 Hysteria2
install_hysteria2() {
    echo "开始安装依赖包..."
    install_packages
    echo "生成随机密码..."
    generate_password
    echo "获取端口配置..."
    get_port
    echo "获取域名与邮箱..."
    get_domain_and_email
    echo "获取伪装站点配置..."
    get_masquerade_url
    check_domain_resolution

    echo "下载并安装 Hysteria2..."
    if ! bash <(curl -fsSL https://get.hy2.sh/); then
        echo "错误: Hysteria2 安装失败"
        exit 1
    fi

    issue_letsencrypt_cert

    echo "创建 Hysteria2 配置文件..."
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
    url: ${MASQUERADE_URL}
    rewriteHost: true

quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow: 26843545
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
EOF

    echo "启动 Hysteria2 服务..."
    if check_systemd; then
        systemctl daemon-reload
        systemctl enable hysteria-server.service
        systemctl restart hysteria-server.service
        sleep 2
    else
        echo "请手动启动 Hysteria2 服务"
    fi

    cat > /etc/hysteria/hyclient.json << EOF
{
"server": "${DOMAIN}:${SERVER_PORT}",
"auth": "${HYSTERIA_PASSWORD}",
"tls": {
  "sni": "${DOMAIN}"
},
"quic": {
  "initStreamReceiveWindow": 26843545,
  "maxStreamReceiveWindow": 26843545,
  "initConnReceiveWindow": 67108864,
  "maxConnReceiveWindow": 67108864
}
}
EOF
    rm -f tcp-wss.sh hy2.sh
}

# 服务状态检查
check_service_status() {
    echo -e "${CYAN}===== 服务状态 =====${RESET}"
    if command -v systemctl &> /dev/null; then
        if systemctl is-active --quiet hysteria-server.service; then
            echo -e "${GREEN}✓ Hysteria2 服务运行正常${RESET}"
        else
            echo -e "${RED}✗ Hysteria2 服务未运行，可执行 journalctl -u hysteria-server -e 查看日志${RESET}"
        fi
    else
        if pgrep -f hysteria &> /dev/null; then
            echo -e "${GREEN}✓ Hysteria2 进程运行正常${RESET}"
        else
            echo -e "${RED}✗ Hysteria2 进程未运行${RESET}"
        fi
    fi
    echo -e "${CYAN}===================${RESET}"
}

# 输出客户端配置
show_client_config() {
    local connection_link="${HYSTERIA_PASSWORD}@${DOMAIN}:${SERVER_PORT}/?sni=${DOMAIN}#Hysteria2-${DOMAIN}"

    echo
    echo -e "${GREEN}===== Hysteria2 安装完成 (Let's Encrypt 真证书) =====${RESET}"
    echo
    echo -e "${CYAN}=========== 配置参数 =============${RESET}"
    echo -e "服务器域名 (SNI): ${YELLOW}${DOMAIN}${RESET}"
    echo -e "端口            : ${YELLOW}${SERVER_PORT}${RESET}"
    echo -e "密码            : ${YELLOW}${HYSTERIA_PASSWORD}${RESET}"
    echo -e "伪装网站        : ${YELLOW}${MASQUERADE_URL}${RESET}"
    echo -e "证书类型        : ${YELLOW}Let's Encrypt (自动续期)${RESET}"
    echo -e "${CYAN}==================================${RESET}"
    echo
    echo -e "${CYAN}连接链接:${RESET}"
    echo -e "${GREEN}hysteria2://${connection_link}${RESET}"
    echo
    echo -e "客户端配置文件已保存到: ${YELLOW}/etc/hysteria/hyclient.json${RESET}"
    echo
    echo -e "${CYAN}注意事项:${RESET}"
    echo -e "1. 请确保防火墙/安全组允许端口 ${YELLOW}${SERVER_PORT}/UDP${RESET} 及 ${YELLOW}80/TCP${RESET}(仅签证时需要) 通过"
    echo -e "2. 配置文件位置: ${YELLOW}/etc/hysteria/config.yaml${RESET}"
    echo -e "3. 证书由 acme.sh 自动续期，续期后会自动重启 Hysteria2 服务"
    echo -e "4. 服务管理命令:"
    echo -e "   启动: ${GREEN}systemctl start hysteria-server${RESET}"
    echo -e "   停止: ${GREEN}systemctl stop hysteria-server${RESET}"
    echo -e "   重启: ${GREEN}systemctl restart hysteria-server${RESET}"
    echo -e "   状态: ${GREEN}systemctl status hysteria-server${RESET}"
    echo
}

main() {
    echo "Hysteria2 一键安装脚本 (Let's Encrypt 版)"
    echo "支持的系统: Ubuntu/Debian/CentOS/RHEL/AlmaLinux/Rocky Linux/Arch Linux"
    echo

    install_hysteria2
    show_client_config
    check_service_status
}

main
