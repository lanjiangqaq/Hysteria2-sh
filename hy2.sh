#!/bin/bash
# Hysteria2 Automated Installation & Management Script (IPv4 Edition)
# Author: Modified for Production, Security, Port Hopping & Force IPv4
# Optimized: Bandwidth (Brutal CC) + kernel/UDP tuning + BDP QUIC windows
#            + WARP SOCKS5 split-routing (geosite/domain) + thorough uninstall

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

    # 已移除 psmisc：释放 80 端口只使用 lsof + kill，不依赖 psmisc 提供的 fuser/killall
    if command -v apt-get &> /dev/null; then
        apt-get update -y
        apt-get install -y curl wget openssl gawk ca-certificates socat lsof iptables iproute2 cron gpg lsb-release
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

# ================= 带宽速率设置 =================
get_bandwidth() {
    echo -e "${CYAN}===== 带宽速率设置 (Brutal 拥塞控制) =====${RESET}"
    echo "说明: 准确填写服务器的真实出口上下行带宽，Hysteria2 将自动切换为 Brutal 拥塞控制算法，"
    echo "      相比默认 BBR 在高延迟跨境链路下能更快跑满带宽、减少丢包抖动带来的降速。"
    echo "      不确定可运行 speedtest-cli 或询问机房实际带宽；留空则跳过，使用默认自适应模式。"
    read -p "请输入服务器上行带宽 (单位 Mbps, 直接回车跳过): " UP_MBPS
    read -p "请输入服务器下行带宽 (单位 Mbps, 直接回车跳过): " DOWN_MBPS

    if [[ -n "$UP_MBPS" && ! "$UP_MBPS" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}输入无效，已忽略上行带宽设置。${RESET}"
        UP_MBPS=""
    fi
    if [[ -n "$DOWN_MBPS" && ! "$DOWN_MBPS" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}输入无效，已忽略下行带宽设置。${RESET}"
        DOWN_MBPS=""
    fi

    if [[ -n "$UP_MBPS" && -z "$DOWN_MBPS" ]] || [[ -z "$UP_MBPS" && -n "$DOWN_MBPS" ]]; then
        echo -e "${YELLOW}提示: 上下行必须同时填写才能生效，已忽略本次输入，改用自适应模式。${RESET}"
        UP_MBPS=""
        DOWN_MBPS=""
    fi
    echo -e "${CYAN}==========================================${RESET}"
}

# ================= 内核网络参数调优 =================
optimize_kernel_params() {
    echo -e "${YELLOW}正在优化内核网络参数 (BBR / UDP 缓冲区 / 队列算法)...${RESET}"

    SYSCTL_CONF="/etc/sysctl.d/99-hysteria-tuning.conf"
    cat > "$SYSCTL_CONF" << EOF
# Hysteria2 高带宽/高延迟场景网络优化 (脚本自动生成)
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=33554432
net.core.wmem_default=33554432
net.ipv4.udp_mem=1638400 3276800 6553600
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384
net.ipv4.ip_forward=1
fs.file-max=1000000
EOF

    modprobe tcp_bbr 2>/dev/null
    sysctl --system >/dev/null 2>&1

    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        echo -e "${GREEN}✓ BBR 拥塞控制已启用${RESET}"
    else
        echo -e "${YELLOW}提示: 当前内核可能不支持 BBR，已跳过该项（不影响 Brutal 拥塞控制生效）。${RESET}"
    fi
    echo -e "${GREEN}✓ 内核参数优化完成 (UDP 收发缓冲区已提升至 64MB)${RESET}"
}

# ================= WARP SOCKS5 分流设置 =================
resolve_site_rule() {
    # 将用户输入的服务名/域名，自动匹配为 geosite 分类或 domain-suffix / domain-keyword 规则
    local input="$1"
    local lower
    lower=$(echo "$input" | tr '[:upper:]' '[:lower:]' | xargs)

    case "$lower" in
        google) echo "geosite:google" ;;
        youtube) echo "geosite:youtube" ;;
        netflix) echo "geosite:netflix" ;;
        openai|chatgpt|gpt) echo "geosite:openai" ;;
        twitter|x) echo "geosite:twitter" ;;
        facebook|meta) echo "geosite:facebook" ;;
        instagram|ins) echo "geosite:instagram" ;;
        tiktok|douyin) echo "geosite:tiktok" ;;
        telegram|tg) echo "geosite:telegram" ;;
        spotify) echo "geosite:spotify" ;;
        disney|disneyplus) echo "geosite:disney" ;;
        hbo|hbomax|max) echo "geosite:hbo" ;;
        amazon) echo "geosite:amazon" ;;
        apple) echo "geosite:apple" ;;
        microsoft) echo "geosite:microsoft" ;;
        github) echo "geosite:github" ;;
        reddit) echo "geosite:reddit" ;;
        whatsapp) echo "geosite:whatsapp" ;;
        line) echo "geosite:line" ;;
        discord) echo "geosite:discord" ;;
        twitch) echo "geosite:twitch" ;;
        steam) echo "geosite:steam" ;;
        bing) echo "geosite:bing" ;;
        *)
            # 形如 example.com 的合法域名 -> domain-suffix，否则按关键词匹配 -> domain-keyword
            if [[ "$lower" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
                echo "domain-suffix:${lower}"
            else
                echo "domain-keyword:${lower}"
            fi
            ;;
    esac
}

download_geo_data() {
    echo -e "${YELLOW}正在下载 geosite/geoip 分流规则数据库...${RESET}"
    mkdir -p /etc/hysteria
    curl -fsSL -o /etc/hysteria/geoip.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
    curl -fsSL -o /etc/hysteria/geosite.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
    if [ -s /etc/hysteria/geoip.dat ] && [ -s /etc/hysteria/geosite.dat ]; then
        echo -e "${GREEN}✓ 分流规则数据库下载完成${RESET}"
    else
        echo -e "${RED}✗ 分流规则数据库下载失败，domain-suffix/domain-keyword 规则仍可正常工作，但 geosite 类规则可能无法匹配。${RESET}"
    fi
}

setup_warp_socks5() {
    echo -e "${YELLOW}正在检测/安装 Cloudflare WARP 客户端...${RESET}"
    WARP_INSTALLED_BY_SCRIPT="no"

    if ! command -v warp-cli &> /dev/null; then
        if command -v apt-get &> /dev/null; then
            curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list > /dev/null
            apt-get update -y
            apt-get install -y cloudflare-warp
            WARP_INSTALLED_BY_SCRIPT="yes"
        else
            echo -e "${RED}未检测到 apt 包管理器，Cloudflare WARP 官方仅提供 Debian/Ubuntu 安装包。${RESET}"
            echo -e "${RED}请参考 https://pkg.cloudflareclient.com/ 手动安装 warp-cli 后重新运行本脚本，本次将跳过分流功能。${RESET}"
            ENABLE_SPLIT="n"
            return
        fi
    fi

    # warp-cli 不同版本命令略有差异，这里做新旧语法双重尝试
    warp-cli --accept-tos registration new 2>/dev/null || warp-cli --accept-tos register 2>/dev/null || true
    warp-cli --accept-tos mode proxy 2>/dev/null || warp-cli --accept-tos set-mode proxy 2>/dev/null
    warp-cli --accept-tos proxy port "$WARP_SOCKS_PORT" 2>/dev/null || warp-cli --accept-tos set-proxy-port "$WARP_SOCKS_PORT" 2>/dev/null
    warp-cli --accept-tos connect 2>/dev/null

    sleep 3
    if warp-cli --accept-tos status 2>/dev/null | grep -qi "Connected"; then
        echo -e "${GREEN}✓ WARP SOCKS5 代理已启动，监听端口: 127.0.0.1:${WARP_SOCKS_PORT}${RESET}"
    else
        echo -e "${RED}✗ WARP 连接状态异常，请稍后手动执行 'warp-cli status' 排查（不同版本命令可能略有差异）。${RESET}"
    fi
}

get_split_routing() {
    echo -e "${CYAN}===== WARP SOCKS5 分流设置 =====${RESET}"
    echo "说明: 可将指定网站/服务的流量通过本机 Cloudflare WARP (SOCKS5) 分流出去，"
    echo "      其余流量仍走 Hysteria2 直连。适合希望特定网站(如 ChatGPT/Netflix)走 WARP 原生 IP 的场景。"
    read -p "是否启用 WARP SOCKS5 分流? [y/N]: " ENABLE_SPLIT

    if [[ ! "$ENABLE_SPLIT" =~ ^[Yy]$ ]]; then
        ENABLE_SPLIT="n"
        echo -e "${CYAN}==================================${RESET}"
        return
    fi

    WARP_SOCKS_PORT=40000
    setup_warp_socks5

    if [[ ! "$ENABLE_SPLIT" =~ ^[Yy]$ ]]; then
        echo -e "${CYAN}==================================${RESET}"
        return
    fi

    echo "请输入需要走 WARP 分流的网站，用逗号分隔。"
    echo "可以输入常见服务名 (如: netflix, openai, google, youtube, tiktok...)，也可以直接输入完整域名 (如: example.com)。"
    read -p "分流网站列表: " SPLIT_SITES_RAW

    SPLIT_RULES=()
    IFS=',' read -ra SITE_ARR <<< "$SPLIT_SITES_RAW"
    for site in "${SITE_ARR[@]}"; do
        site_trimmed=$(echo "$site" | xargs)
        if [ -z "$site_trimmed" ]; then continue; fi
        rule=$(resolve_site_rule "$site_trimmed")
        SPLIT_RULES+=("$rule")
        echo -e "  ${GREEN}✓${RESET} ${site_trimmed} -> ${YELLOW}${rule}${RESET}"
    done

    if [ ${#SPLIT_RULES[@]} -eq 0 ]; then
        echo -e "${YELLOW}未输入任何有效网站，已跳过分流规则设置。${RESET}"
        ENABLE_SPLIT="n"
    else
        download_geo_data
    fi
    echo -e "${CYAN}==================================${RESET}"
}

# ================= 真实 IP 探测与域名校验 (修复 DNS 解析误判) =================
check_domain_and_ip() {
    echo -e "${CYAN}===== 网络环境与真实 IP 强制检测 =====${RESET}"
    echo -e "${YELLOW}正在穿透虚拟网卡，探测本机物理公网 IPv4...${RESET}"

    DEFAULT_IFACE=$(ip -4 route ls | awk '/default/ && !/wg|warp|tun|tailscale/ {print $5; exit}')
    if [ -z "$DEFAULT_IFACE" ]; then DEFAULT_IFACE=$(ip -4 route ls | awk '/default/ {print $5; exit}'); fi
    REAL_IPV4=$(curl -s --interface "$DEFAULT_IFACE" -4 https://ipv4.icanhazip.com 2>/dev/null)
    if [ -z "$REAL_IPV4" ]; then REAL_IPV4=$(curl -s -4 https://ipv4.icanhazip.com 2>/dev/null); fi

    echo -e "物理网卡 IPv4: ${GREEN}${REAL_IPV4:-未分配}${RESET}"

    echo -e "${YELLOW}正在通过公共 DNS 请求 $DOMAIN 的解析记录...${RESET}"

    # 使用严谨的正则匹配，彻底排除 SOA 记录干扰，只抓取合法的 IPv4/IPv6 格式
    DOMAIN_IPV4=$(curl -sH "accept: application/dns-json" "https://cloudflare-dns.com/dns-query?name=$DOMAIN&type=A" | grep -oP '(?<="data":")[^"]*' | grep -E "^([0-9]{1,3}\.){3}[0-9]{1,3}$" | head -n 1)
    DOMAIN_IPV6=$(curl -sH "accept: application/dns-json" "https://cloudflare-dns.com/dns-query?name=$DOMAIN&type=AAAA" | grep -oP '(?<="data":")[^"]*' | grep -E "^[0-9a-fA-F:]+$" | head -n 1)

    echo -e "域名解析 IPv4: ${GREEN}${DOMAIN_IPV4:-未解析}${RESET}"

    if [ -n "$DOMAIN_IPV6" ]; then
        echo -e "${RED}========================================================================${RESET}"
        echo -e "${RED} 严重警告: 您的域名仍然配置了真实的 AAAA (IPv6) 解析记录: ${DOMAIN_IPV6} ${RESET}"
        echo -e "${RED} 因为您的 VPS 是纯 IPv4 环境，该记录必定导致证书申请超时，客户端也无法连接！${RESET}"
        echo -e "${RED} 请务必前往 Cloudflare 删除所有 AAAA 记录，等待1-2分钟后再试。${RESET}"
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

# ================= 端口 80 环境处理 =================
release_port_80() {
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

    echo -e "${YELLOW}正在配置防火墙放行 80 端口...${RESET}"
    if command -v ufw >/dev/null 2>&1; then
        ufw allow 80/tcp >/dev/null 2>&1
    fi
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=80/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1
    fi
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
        echo -e "${YELLOW}检测到 wgcf 正在运行！已纳入自动断开策略。${RESET}"
        ACME_PRE_HOOK="${ACME_PRE_HOOK} wg-quick down wgcf >/dev/null 2>&1;"
        ACME_POST_HOOK="${ACME_POST_HOOK} wg-quick up wgcf >/dev/null 2>&1;"
        wg-quick down wgcf >/dev/null 2>&1
        WGCF_TEMP_STOPPED=true
    fi

    eval "$ACME_PRE_HOOK"
    release_port_80
}

restore_warp_if_needed() {
    if [ "$WARP_CLI_TEMP_STOPPED" = true ]; then
        warp-cli connect >/dev/null 2>&1
    fi
    if [ "$WGCF_TEMP_STOPPED" = true ]; then
        wg-quick up wgcf >/dev/null 2>&1
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
    echo "获取带宽配置..."
    get_bandwidth
    echo "获取分流配置..."
    get_split_routing

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

    echo "为 $DOMAIN 申请 TLS 证书 (强制开启 IPv4 监听模式)..."
    if ! /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --listen-v4 -k ec-256 \
        --pre-hook "$ACME_PRE_HOOK" \
        --post-hook "$ACME_POST_HOOK"; then
        echo -e "${RED}错误: 证书申请失败。请确认 80 端口完全开放且云服务商(控制台)防火墙未阻拦。${RESET}"
        restore_warp_if_needed
        exit 1
    fi

    mkdir -p /etc/hysteria/
    /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
        --key-file /etc/hysteria/server.key \
        --fullchain-file /etc/hysteria/server.crt \
        --reloadcmd "systemctl restart hysteria-server"

    restore_warp_if_needed

    if id hysteria &> /dev/null; then
        chown -R hysteria:hysteria /etc/hysteria
    fi
    chmod 600 /etc/hysteria/server.key
    chmod 644 /etc/hysteria/server.crt

    # 优化内核网络参数，提升机器整体转发能力与 Hysteria2 抗高延迟表现
    optimize_kernel_params

    # 依据带宽时延积 (BDP) 计算 QUIC 接收窗口，替代此前无意义的随机取值，
    # 使窗口大小与真实链路带宽/延迟匹配，减少高延迟场景下的吞吐瓶颈
    EFFECTIVE_DOWN_MBPS=${DOWN_MBPS:-100}
    STREAM_RW=$(awk -v mbps="$EFFECTIVE_DOWN_MBPS" 'BEGIN{
        bdp = int(mbps * 1000000 / 8 * 0.2);
        floor = 16777216;
        cap = 67108864;
        if (bdp < floor) bdp = floor;
        if (bdp > cap) bdp = cap;
        print bdp;
    }')
    CONN_RW=$((STREAM_RW * 2))
    if [ "$CONN_RW" -gt 134217728 ]; then
        CONN_RW=134217728
    fi

    BANDWIDTH_BLOCK=""
    if [[ -n "$UP_MBPS" && -n "$DOWN_MBPS" ]]; then
        BANDWIDTH_BLOCK="
bandwidth:
  up: ${UP_MBPS} mbps
  down: ${DOWN_MBPS} mbps"
    fi

    OUTBOUNDS_BLOCK=""
    ACL_BLOCK=""
    if [[ "$ENABLE_SPLIT" =~ ^[Yy]$ ]]; then
        ACL_LINES=""
        for rule in "${SPLIT_RULES[@]}"; do
            ACL_LINES="${ACL_LINES}
    - warp_socks(${rule})"
        done
        OUTBOUNDS_BLOCK="
outbounds:
  - name: warp_socks
    type: socks5
    socks5:
      addr: 127.0.0.1:${WARP_SOCKS_PORT}"
        ACL_BLOCK="
acl:
  inline:${ACL_LINES}
    - direct(all)
  geoip: /etc/hysteria/geoip.dat
  geosite: /etc/hysteria/geosite.dat"
    fi

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
${BANDWIDTH_BLOCK}
${OUTBOUNDS_BLOCK}
${ACL_BLOCK}
EOF

    # 保存安装信息，供卸载脚本精确清理端口跳跃规则 / WARP 等关联资源
    cat > /etc/hysteria/.install_info << EOF
DOMAIN=$DOMAIN
SERVER_PORT=$SERVER_PORT
ENABLE_PORT_HOP=$ENABLE_PORT_HOP
PORT_HOP_RANGE=$PORT_HOP_RANGE
ENABLE_SPLIT=$ENABLE_SPLIT
WARP_SOCKS_PORT=$WARP_SOCKS_PORT
WARP_INSTALLED_BY_SCRIPT=$WARP_INSTALLED_BY_SCRIPT
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
        if [[ "$ENABLE_SPLIT" =~ ^[Yy]$ ]]; then
            if warp-cli status 2>/dev/null | grep -qi "Connected"; then
                echo -e "${GREEN}✓ WARP SOCKS5 分流出口运行正常${RESET}"
            else
                echo -e "${RED}✗ WARP SOCKS5 未连接，分流规则不会生效，请检查 warp-cli status${RESET}"
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

    if [[ -n "$UP_MBPS" && -n "$DOWN_MBPS" ]]; then
        local BW_STATUS="${UP_MBPS} Mbps 上行 / ${DOWN_MBPS} Mbps 下行 (Brutal 拥塞控制)"
    else
        local BW_STATUS="未设置 (自适应 BBR 模式)"
    fi

    if [[ "$ENABLE_SPLIT" =~ ^[Yy]$ ]]; then
        local SPLIT_STATUS="已启用 (WARP SOCKS5 127.0.0.1:${WARP_SOCKS_PORT}, 共 ${#SPLIT_RULES[@]} 条规则)"
    else
        local SPLIT_STATUS="未启用"
    fi

    local connection_link="${HYSTERIA_PASSWORD}@${DOMAIN}:${SERVER_PORT}/?sni=${DOMAIN}${MPORT_PARAM}#${DOMAIN}"

    echo
    echo -e "${GREEN}===== Hysteria2 安装与配置完成 =====${RESET}"
    echo
    echo -e "${CYAN}=========== 配置参数 =============${RESET}"
    echo -e "服务器域名 (SNI): ${YELLOW}${DOMAIN}${RESET}"
    echo -e "主监听端口      : ${YELLOW}${SERVER_PORT}${RESET}"
    echo -e "端口跳跃状态    : ${YELLOW}${HOP_STATUS}${RESET}"
    echo -e "带宽速率设置    : ${YELLOW}${BW_STATUS}${RESET}"
    echo -e "内核参数优化    : ${YELLOW}已启用 (BBR + fq + 64MB UDP 缓冲区)${RESET}"
    echo -e "WARP 分流状态   : ${YELLOW}${SPLIT_STATUS}${RESET}"
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
    echo -e "${YELLOW}开始执行 Hysteria2 彻底卸载与系统还原程序...${RESET}"

    # 读取安装时保存的信息，确保端口跳跃/WARP 等关联资源能被精确清理
    if [ -f /etc/hysteria/.install_info ]; then
        # shellcheck disable=SC1091
        source /etc/hysteria/.install_info
    fi

    if command -v systemctl &> /dev/null; then
        if [ -f /etc/systemd/system/hysteria-porthop.service ]; then
            echo -e "${YELLOW}正在清理端口跳跃 iptables 规则...${RESET}"
            systemctl stop hysteria-porthop.service 2>/dev/null || true
            systemctl disable hysteria-porthop.service 2>/dev/null || true
            rm -f /etc/systemd/system/hysteria-porthop.service
        fi
        # 双重保险：即使 systemd 单元 ExecStop 未成功执行，也主动清理残留 NAT 规则
        if [ -n "$PORT_HOP_RANGE" ] && [ -n "$SERVER_PORT" ]; then
            PORT_START=$(echo "$PORT_HOP_RANGE" | cut -d'-' -f1)
            PORT_END=$(echo "$PORT_HOP_RANGE" | cut -d'-' -f2)
            if [ -n "$PORT_START" ] && [ -n "$PORT_END" ]; then
                iptables -t nat -D PREROUTING -p udp --dport "${PORT_START}:${PORT_END}" -j REDIRECT --to-ports "${SERVER_PORT}" 2>/dev/null || true
            fi
        fi
        systemctl daemon-reload
    fi

    echo -e "${YELLOW}正在使用官方安装脚本彻底移除 Hysteria2 核心与服务...${RESET}"
    if command -v curl &> /dev/null; then
        bash <(curl -fsSL https://get.hy2.sh/) --remove 2>/dev/null || true
    fi

    # 双重保险：手动清理可能残留的服务与二进制文件
    if command -v systemctl &> /dev/null; then
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
    rm -f /usr/local/bin/hysteria
    rm -rf /etc/hysteria
    rm -rf /usr/local/etc/hysteria
    rm -rf /var/log/hysteria

    echo -e "${YELLOW}正在清理 acme.sh 证书环境与自动续期任务...${RESET}"
    if [ -f "/root/.acme.sh/acme.sh" ]; then
        /root/.acme.sh/acme.sh --uninstall >/dev/null 2>&1
    fi
    rm -rf /root/.acme.sh
    if command -v crontab &> /dev/null; then
        crontab -l 2>/dev/null | grep -v 'acme.sh' | crontab - 2>/dev/null || true
    fi

    echo -e "${YELLOW}正在清理内核调优配置...${RESET}"
    rm -f /etc/sysctl.d/99-hysteria-tuning.conf
    sysctl --system >/dev/null 2>&1 || true

    if [[ "$ENABLE_SPLIT" =~ ^[Yy]$ ]] && [ "$WARP_INSTALLED_BY_SCRIPT" = "yes" ]; then
        read -p "检测到本脚本曾自动安装 Cloudflare WARP 客户端，是否一并卸载? [y/N]: " REMOVE_WARP
        if [[ "$REMOVE_WARP" =~ ^[Yy]$ ]]; then
            warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
            systemctl stop warp-svc 2>/dev/null || true
            systemctl disable warp-svc 2>/dev/null || true
            if command -v apt-get &> /dev/null; then
                apt-get remove --purge -y cloudflare-warp >/dev/null 2>&1
                apt-get autoremove -y >/dev/null 2>&1
            fi
            rm -f /etc/apt/sources.list.d/cloudflare-client.list
            rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            rm -rf /var/lib/cloudflare-warp
            echo -e "${GREEN}✓ Cloudflare WARP 客户端已卸载${RESET}"
        fi
    fi

    echo -e "${YELLOW}正在清理服务日志...${RESET}"
    if command -v journalctl &> /dev/null; then
        journalctl --rotate >/dev/null 2>&1 || true
        journalctl --vacuum-time=1s -u hysteria-server >/dev/null 2>&1 || true
    fi

    SCRIPT_PATH=$(readlink -f "$0")
    rm -f "$SCRIPT_PATH"

    echo -e "${GREEN}======================================================${RESET}"
    echo -e "${GREEN} 卸载完成！Hysteria 2 核心、证书、内核调优、分流规则数据库及定时任务均已清除，系统已恢复至初始状态。${RESET}"
    echo -e "${GREEN}======================================================${RESET}"
    exit 0
}

# ================= 主控制菜单 =================
show_menu() {
    clear
    echo -e "${GREEN}======================================================${RESET}"
    echo -e "${GREEN}      Hysteria 2 自动化部署与管理脚本 (IPv4 优化版)         ${RESET}"
    echo -e "${GREEN}======================================================${RESET}"
    echo -e "${CYAN} 1.${RESET} 安装 Hysteria 2 (端口跳跃 / 带宽调速 / 内核优化 / WARP分流)"
    echo -e "${CYAN} 2.${RESET} 彻底卸载 Hysteria 2 (彻底清理规则与环境)"
    echo -e "${CYAN} 0.${RESET} 退出脚本"
    echo -e "${GREEN}======================================================${RESET}"
    echo ""

    read -p "请输入对应的数字以选择功能: " choice

    case $choice in
        1)
            install_hysteria2
            ;;
        2)
            read -p "您确定要彻底卸载 Hysteria 2、清理防火墙规则并删除此脚本自身吗？[y/N]: " confirm
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
