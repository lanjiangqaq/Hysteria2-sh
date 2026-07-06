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

# 收集用户必要信息 (循环验证输入不能为空)
get_user_input() {
    echo -e "${CYAN}===== 证书配置信息获取 =====${RESET}"
    
    while true; do
        read -p "请输入您已解析至本机的真实域名 (用于申请证书与 SNI): " DOMAIN
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
    
    echo -e "${CYAN}============================${RESET}"
}

# 安装必要的包
install_packages() {
    detect_os
    
    echo "检测到操作系统: $DETECTED_OS $OS_VERSION"
    
    if command -v apt-get &> /dev/null; then
        echo "使用 APT 包管理器..."
        apt-get update -y
        apt-get install -y curl wget openssl gawk ca-certificates socat lsof
    elif command -v yum &> /dev/null; then
        echo "使用 YUM 包管理器..."
        yum update -y
        yum install -y epel-release
        yum install -y curl wget openssl gawk ca-certificates socat lsof
    elif command -v dnf &> /dev/null; then
        echo "使用 DNF 包管理器..."
        dnf update -y
        dnf install -y curl wget openssl gawk ca-certificates socat lsof
    elif command -v zypper &> /dev/null; then
        echo "使用 Zypper 包管理器..."
        zypper refresh
        zypper install -y curl wget openssl gawk ca-certificates socat lsof
    elif command -v pacman &> /dev/null; then
        echo "使用 Pacman 包管理器..."
        pacman -Syu --noconfirm
        pacman -S --noconfirm curl wget openssl gawk ca-certificates socat lsof
    else
        echo "错误: 未找到支持的包管理器!"
        echo "请手动安装以下依赖: curl wget openssl gawk ca-certificates socat lsof"
        exit 1
    fi
}

# 检查并启用 systemd 服务
check_systemd() {
    if ! command -v systemctl &> /dev/null; then
        echo "警告: systemctl 未找到，可能不支持 systemd"
        echo "请手动管理 hysteria 服务"
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

# 安装 Hysteria2 并配置证书
install_hysteria2() {
    get_user_input
    echo "开始安装依赖包..."
    install_packages
    echo "生成随机密码..."
    generate_password
    echo "获取端口配置..."
    get_port

    echo "释放 80 端口以用于证书验证..."
    if command -v lsof >/dev/null 2>&1; then
        PORT_80_PID=$(lsof -t -i:80 || true)
        if [ -n "$PORT_80_PID" ]; then
            kill -9 $PORT_80_PID
        fi
    fi

    echo "下载并安装 Hysteria2..."
    if ! bash <(curl -fsSL https://get.hy2.sh/); then
        echo "错误: Hysteria2 安装失败"
        exit 1
    fi

    echo "部署 acme.sh 证书管理工具..."
    if [ ! -f "/root/.acme.sh/acme.sh" ]; then
        curl https://get.acme.sh | sh -s email="$EMAIL"
    fi
    
    echo "切换默认 CA 为 Let's Encrypt..."
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt

    echo "为 $DOMAIN 申请 TLS 证书..."
    if ! /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256; then
        echo "错误: 证书申请失败，请检查域名解析是否生效及 80 端口是否被阻塞。"
        exit 1
    fi

    echo "创建配置目录并安装证书..."
    mkdir -p /etc/hysteria/
    /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
        --key-file /etc/hysteria/server.key \
        --fullchain-file /etc/hysteria/server.crt

    if id hysteria &> /dev/null; then
        chown -R hysteria:hysteria /etc/hysteria
    fi
    chmod 600 /etc/hysteria/server.key
    chmod 644 /etc/hysteria/server.crt

    echo "动态生成 QUIC 性能参数..."
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
    url: https://www.bing.com
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

    # 生成客户端标准配置文件
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
            echo -e "${RED}✗ Hysteria2 服务未运行，请执行 journalctl -u hysteria-server 查看日志${RESET}"
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
    local connection_link="${HYSTERIA_PASSWORD}@${DOMAIN}:${SERVER_PORT}/?sni=${DOMAIN}#${DOMAIN}"

    echo
    echo -e "${GREEN}===== Hysteria2 安装与配置完成 =====${RESET}"
    echo
    echo -e "${CYAN}=========== 配置参数 =============${RESET}"
    echo -e "服务器域名 (SNI): ${YELLOW}${DOMAIN}${RESET}"
    echo -e "端口            : ${YELLOW}${SERVER_PORT}${RESET}"
    echo -e "密码            : ${YELLOW}${HYSTERIA_PASSWORD}${RESET}"
    echo -e "防封锁伪装站    : ${YELLOW}https://www.bing.com${RESET}"
    echo -e "QUIC Stream 窗口: ${YELLOW}${STREAM_RW}${RESET}"
    echo -e "QUIC Conn 窗口  : ${YELLOW}${CONN_RW}${RESET}"
    echo -e "跳过证书验证    : ${YELLOW}false (已启用严格安全校验)${RESET}"
    echo -e "${CYAN}==================================${RESET}"
    echo
    echo -e "${CYAN}连接链接 (URI 格式):${RESET}"
    echo -e "${GREEN}hysteria2://${connection_link}${RESET}"
    echo
    echo -e "客户端配置文件已保存到: ${YELLOW}/etc/hysteria/hyclient.json${RESET}"
    echo
    echo -e "${CYAN}注意事项:${RESET}"
    echo -e "1. 请确保防火墙允许 ${YELLOW}${SERVER_PORT}/UDP${RESET} 端口通过。"
    echo -e "2. 请确保服务器的 ${YELLOW}80/TCP${RESET} 端口未被屏蔽，以保障后续证书自动续期。"
    echo -e "3. 服务端配置文件位置: ${YELLOW}/etc/hysteria/config.yaml${RESET}"
    echo -e "4. 服务管理命令:"
    echo -e "   启动: ${GREEN}systemctl start hysteria-server${RESET}"
    echo -e "   停止: ${GREEN}systemctl stop hysteria-server${RESET}"
    echo -e "   重启: ${GREEN}systemctl restart hysteria-server${RESET}"
    echo -e "   状态: ${GREEN}systemctl status hysteria-server${RESET}"
    echo
}

# 彻底卸载 Hysteria2
uninstall_hysteria2() {
    echo -e "${YELLOW}开始执行 Hysteria2 彻底卸载程序...${RESET}"
    
    # 停止并禁用守护进程
    if command -v systemctl &> /dev/null; then
        echo "停止并禁用 hysteria-server 服务..."
        systemctl stop hysteria-server.service 2>/dev/null || true
        systemctl disable hysteria-server.service 2>/dev/null || true
        rm -f /etc/systemd/system/hysteria-server.service
        systemctl daemon-reload
    fi

    # 清理正在运行的孤儿进程
    if pgrep -f hysteria &> /dev/null; then
        echo "终止残留的 Hysteria 进程..."
        pkill -f hysteria
    fi

    # 移除核心程序与配置文件
    echo "删除核心二进制文件及配置目录..."
    rm -f /usr/local/bin/hysteria
    rm -rf /etc/hysteria

    echo -e "${GREEN}======================================================${RESET}"
    echo -e "${GREEN} Hysteria2 及其配置文件、证书副本均已从系统中彻底卸载 ${RESET}"
    echo -e "${GREEN}======================================================${RESET}"
}

# 主菜单交互界面
show_menu() {
    clear
    echo -e "${GREEN}======================================================${RESET}"
    echo -e "${GREEN}      Hysteria 2 一键部署与管理脚本 (Let's Encrypt 版)    ${RESET}"
    echo -e "${GREEN}======================================================${RESET}"
    echo -e "${CYAN} 1.${RESET} 安装 Hysteria 2 (包含自动签发证书及配置生成)"
    echo -e "${CYAN} 2.${RESET} 彻底卸载 Hysteria 2"
    echo -e "${CYAN} 0.${RESET} 退出脚本"
    echo -e "${GREEN}======================================================${RESET}"
    echo ""
    
    read -p "请输入对应的数字以选择功能: " choice
    
    case $choice in
        1)
            install_hysteria2
            ;;
        2)
            read -p "您确定要彻底卸载 Hysteria 2 及其所有配置文件吗？[y/N]: " confirm
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

# 执行主程序入口
show_menu
