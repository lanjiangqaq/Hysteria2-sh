#!/bin/bash
# ==============================================================================
# Hysteria 2 自动化部署脚本
# 包含功能：安装核心组件、acme.sh 证书申请 (Let's Encrypt)、自动化配置生成
# ==============================================================================

set -e

# 定义颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}      Hysteria 2 一键部署脚本 (Let's Encrypt 版)      ${NC}"
echo -e "${GREEN}======================================================${NC}"

# 1. 权限与环境检查
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[错误] 请使用 root 权限执行此脚本。${NC}"
  exit 1
fi

# 2. 交互式获取用户参数
read -p "请输入您已解析至本机的真实域名 (用于申请证书与 SNI): " DOMAIN
if [ -z "$DOMAIN" ]; then
    echo -e "${RED}[错误] 域名不能为空。${NC}"
    exit 1
fi

read -p "请输入您期望使用的端口号 (默认 29003): " PORT
PORT=${PORT:-29003}

read -p "请输入您的邮箱 (用于 acme.sh 接收证书通知): " EMAIL
if [ -z "$EMAIL" ]; then
    echo -e "${RED}[错误] 邮箱不能为空。${NC}"
    exit 1
fi

# 3. 安装基础依赖
echo -e "${YELLOW}[信息] 正在安装必要依赖...${NC}"
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y curl socat uuid-runtime
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl socat util-linux
else
    echo -e "${RED}[错误] 不支持的操作系统包管理器。${NC}"
    exit 1
fi

# 4. 释放 80 端口 (停止可能占用 80 端口的服务)
echo -e "${YELLOW}[信息] 检查并释放 80 端口用于证书验证...${NC}"
if command -v lsof >/dev/null 2>&1; then
    PORT_80_PID=$(lsof -t -i:80 || true)
    if [ -n "$PORT_80_PID" ]; then
        kill -9 $PORT_80_PID
    fi
fi

# 5. 安装 Hysteria 2
echo -e "${YELLOW}[信息] 正在安装 Hysteria 2 官方核心...${NC}"
bash <(curl -fsSL https://get.hy2.sh/)

# 6. 安装与配置 acme.sh
echo -e "${YELLOW}[信息] 正在部署 acme.sh 证书管理工具...${NC}"
if [ ! -f "/root/.acme.sh/acme.sh" ]; then
    curl https://get.acme.sh | sh -s email="$EMAIL"
fi
source /root/.acme.sh/acme.env

echo -e "${YELLOW}[信息] 切换默认 CA 为 Let's Encrypt...${NC}"
/root/.acme.sh/acme.sh --set-default-ca --server letsencrypt

# 7. 申请与安装证书
echo -e "${YELLOW}[信息] 开始为 $DOMAIN 申请 TLS 证书...${NC}"
/root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256

mkdir -p /etc/hysteria
/root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
    --key-file /etc/hysteria/server.key \
    --fullchain-file /etc/hysteria/server.crt

# 修复证书权限以供 Hysteria 用户读取
chown -R hysteria:hysteria /etc/hysteria
chmod 600 /etc/hysteria/server.key
chmod 644 /etc/hysteria/server.crt

# 8. 生成配置文件
echo -e "${YELLOW}[信息] 正在生成服务端配置文件...${NC}"
PASSWORD=$(uuidgen || tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)

cat <<EOF > /etc/hysteria/config.yaml
listen: :$PORT

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: $PASSWORD

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true

quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow: 26843545
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
EOF

# 9. 启动服务
echo -e "${YELLOW}[信息] 重启并应用 Hysteria 2 服务...${NC}"
systemctl daemon-reload
systemctl enable hysteria-server
systemctl restart hysteria-server

# 10. 输出结果
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}               部署完成！请保存以下信息               ${NC}"
echo -e "${GREEN}======================================================${NC}"
echo -e "服务器域名 (SNI) : ${YELLOW}$DOMAIN${NC}"
echo -e "端口号           : ${YELLOW}$PORT${NC}"
echo -e "认证密码         : ${YELLOW}$PASSWORD${NC}"
echo -e "防封锁伪装站     : ${YELLOW}https://www.bing.com${NC}"
echo -e "安全策略         : ${YELLOW}需关闭客户端的 allowInsecure (严格验证证书)${NC}"
echo -e ""
echo -e "【通用分享链接 (URI 格式)】:"
echo -e "${GREEN}hy2://$PASSWORD@$DOMAIN:$PORT?sni=$DOMAIN#$DOMAIN${NC}"
echo -e "======================================================"
