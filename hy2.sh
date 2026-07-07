#!/bin/bash
# Hysteria2 Automated Installation & Management Script (Let's Encrypt Edition)
# Author: Modified for Production & Security

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

# 检测操作系统类型
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

# 收集用户必要信息
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
        read -p "请输入您的邮箱 (用于接收证书到期通知): " EMAIL
        if [ -n "$EMAIL" ]; then
            break
        else
            echo -e "${RED}错误: 邮箱不能为空，请重新输入。${RESET}"
        fi
    done
    
    echo -e "${CYAN}===== 伪装站点设置 =====${RESET}"
    echo "当防火墙或审查者主动探测您的节点时，服务端将向其展示该网站的内容。"
    read -p "请输入防主动探测的伪装网站 URL (默认: https://www.bing.com): " MASQUERADE_URL
    
    # 若用户直接回车，则使用默认值
    if [ -z "$MASQUERADE_URL" ]; then
        MASQUERADE_URL="https://www.bing.com"
    # 自动为用户补全 https:// 协议头
    elif [[ ! "$MASQUERADE_URL" =~ ^https?:// ]]; then
        MASQUERADE_URL="https://${MASQUERADE_URL}"
    fi
    echo -e "${CYAN}============================${RESET}"
}

# 安装必要的包
install_packages() {
    detect_os
    
    echo "检测到操作系统: $DETECTED_OS $OS_VERSION"
    
    if command -v apt-get &> /dev/null; then
        apt-get update -y
        apt-get install -y curl wget openssl gawk ca-certificates socat lsof psmisc
    elif command -v yum &> /dev/null; then
        yum update -y
        yum install -y epel-release
        yum install -y curl wget openssl gawk ca-certificates socat lsof psmisc
    elif command -v dnf &> /dev/null; then
        dnf update -y
        dnf install -y curl wget openssl gawk ca-certificates socat lsof psmisc
    elif command -v zypper &> /dev/null; then
        zypper refresh
        zypper install -y curl wget openssl gawk ca-certificates socat lsof psmisc
    elif command -v pacman &> /dev/null; then
        pacman -Syu --noconfirm
        pacman -S --noconfirm curl wget openssl gawk ca-certificates socat lsof psmisc
    else
        echo "错误: 未找到支持的包管理器，请手动安装依赖。"
        exit 1
    fi
}

# 检查 systemd
check_systemd() {
    if ! command -v systemctl &> /dev/null; then
        return 1
    fi
    return 0
}

# 生成随机密码
generate_password() {
    if [ -f /proc/sys/kernel/random/uuid ]; then
        HYSTERIA_PASSWORD=$(cat /proc/sys/kernel/random/uuid | sed 's/-//g' | head -c 16)
    else
        HYSTERIA_PASSWORD=$(openssl rand -hex 8)
    fi
}

# 获取端口
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

# 智能检测并释放 80 端口
release_port_80() {
    echo -e "${YELLOW}开始检测 80 端口占用情况...${RESET}"
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
}

# 安装 Hysteria2 并配置
install_hysteria2() {
    get_user_input
    echo "开始安装依赖包..."
    install_packages
    echo "生成随机密码..."
    generate_password
    echo "获取端口配置..."
    get_port

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

    release_port_80

    echo "为 $DOMAIN 申请 TLS 证书..."
    if ! /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256; then
        echo -e "${RED}错误: 证书申请失败，请确认域名（如 xxx.992989.xyz）已正确输入且解析至本服务器。${RESET}"
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
    url: $MASQUERADE_URL
    rewriteHost: true

quic:
  initStreamReceiveWindow: $STREAM_RW
  maxStreamReceiveWindow: $STREAM_RW
  initConnReceiveWindow: $CONN_RW
  maxConnReceiveWindow: $CONN_RW
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
    "sni": "${DOMAIN}",
    "insecure": false
  },
  "quic": {
    "initStreamReceiveWindow": $STREAM_RW,
    "maxStreamReceiveWindow": $STREAM_RW,
    "initConnReceiveWindow": $CONN_RW,
    "maxConnReceiveWindow": $CONN_RW
  }
}
EOF
    rm -f tcp-wss.sh hy2.sh
    
    show_client_config
    check_service_status
}

# 服务状态检查
check_service_status() {
    echo -e "${CYAN}===== 服务状态 =====${RESET}"
    if command -v systemctl &> /dev/null; then
        if systemctl is-active --quiet hysteria-server.service; then
            echo -e "${GREEN}✓ Hysteria2 服务运行正常${RESET}"
        else
            echo -e "${RED}✗ Hysteria2 服务未运行，请执行 journalctl -u hysteria-server -e 查看日志${RESET}"
        fi
    fi
    echo -e "${CYAN}===================${RESET}"
}

# 输出客户端配置
show_client_config() {
    local connection_link="${HYSTERIA_PASSWORD}@${DOMAIN}:${SERVER_PORT}/?sni=${DOMAIN}#${DOMAIN}"

    echo
    echo -e "${GREEN}===== Hysteria2 安装与配置完成 =====${RESET}"
    echo
    echo -e "${CYAN}=========== 配置参数 =============${RESET}"
    echo -e "服务器域名 (SNI): ${YELLOW}${DOMAIN}${RESET}"
    echo -e "端口            : ${YELLOW}${SERVER_PORT}${RESET}"
    echo -e "密码            : ${YELLOW}${HYSTERIA_PASSWORD}${RESET}"
    echo -e "服务端伪装站    : ${YELLOW}${MASQUERADE_URL}${RESET}"
    echo -e "QUIC Stream 窗口: ${YELLOW}${STREAM_RW}${RESET}"
    echo -e "QUIC Conn 窗口  : ${YELLOW}${CONN_RW}${RESET}"
    echo -e "路由分流模式    : ${YELLOW}未启用 (全量直连)${RESET}"
    echo -e "${CYAN}==================================${RESET}"
    echo
    echo -e "${CYAN}连接链接 (URI 格式):${RESET}"
    echo -e "${GREEN}hysteria2://${connection_link}${RESET}"
    echo
    echo -e "客户端配置文件已保存到: ${YELLOW}/etc/hysteria/hyclient.json${RESET}"
    echo
}

# 彻底卸载 Hysteria2
uninstall_hysteria2() {
    echo -e "${YELLOW}开始执行 Hysteria2 彻底卸载程序...${RESET}"
    if command -v systemctl &> /dev/null; then
        systemctl stop hysteria-server.service 2>/dev/null || true
        systemctl disable hysteria-server.service 2>/dev/null || true
        rm -f /etc/systemd/system/hysteria-server.service
        systemctl daemon-reload
    fi
    if pgrep -f hysteria &> /dev/null; then
        pkill -f hysteria
    fi
    rm -f /usr/local/bin/hysteria
    rm -rf /etc/hysteria

    SCRIPT_PATH=$(readlink -f "$0")
    rm -f "$SCRIPT_PATH"

    echo -e "${GREEN}======================================================${RESET}"
    echo -e "${GREEN} Hysteria2 已彻底卸载，本地部署脚本已被一并删除。     ${RESET}"
    echo -e "${GREEN}======================================================${RESET}"
    exit 0
}

# 主菜单
show_menu() {
    clear
    echo -e "${GREEN}======================================================${RESET}"
    echo -e "${GREEN}      Hysteria 2 一键部署与管理脚本 (Let's Encrypt 版)    ${RESET}"
    echo -e "${GREEN}======================================================${RESET}"
    echo -e "${CYAN} 1.${RESET} 安装 Hysteria 2 (包含自动签发证书及自定义伪装)"
    echo -e "${CYAN} 2.${RESET} 彻底卸载 Hysteria 2 (并删除本脚本)"
    echo -e "${CYAN} 0.${RESET} 退出脚本"
    echo -e "${GREEN}======================================================${RESET}"
    echo ""
    
    read -p "请输入对应的数字以选择功能: " choice
    
    case $choice in
        1)
            install_hysteria2
            ;;
        2)
            read -p "您确定要彻底卸载 Hysteria 2 并删除此脚本自身吗？[y/N]: " confirm
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
