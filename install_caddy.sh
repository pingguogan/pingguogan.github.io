#!/bin/bash
set -e

echo "[+] 开始安装 Caddy 官方源..."

# 检查 root
if [ "$(id -u)" -ne 0 ]; then
    echo "[!] 请使用 root 用户运行：sudo bash install_caddy.sh"
    exit 1
fi

# 安装依赖
apt update
apt install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg

# 添加 Caddy GPG key
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

# 添加 Caddy 软件源
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    -o /etc/apt/sources.list.d/caddy-stable.list

# 设置权限
chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
chmod o+r /etc/apt/sources.list.d/caddy-stable.list

# 更新软件源并安装 Caddy
apt update
apt install -y caddy

# 启动并设置开机自启
systemctl enable --now caddy

echo "[+] Caddy 安装完成"
caddy version
