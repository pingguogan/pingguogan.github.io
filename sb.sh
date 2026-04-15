#!/bin/bash

set -e

echo "[+] 禁止 root 远程密码登录（仅允许密钥）..."

# 1. 备份配置
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

# 2. 设置 root 仅允许密钥登录
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config

# 3. （可选）确保密码认证开启（不影响 root，但允许普通用户用密码）
if ! grep -q "^PasswordAuthentication" /etc/ssh/sshd_config; then
    echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
else
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
fi

# 4. 重启 SSH 服务
echo "[+] 重启 SSH 服务..."
systemctl restart ssh

echo "[✓] 已完成：root 禁止密码登录，仅允许密钥登录"
