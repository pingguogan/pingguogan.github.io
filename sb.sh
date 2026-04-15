#!/bin/bash

set -e

echo "[+] 检测系统类型..."

# 识别系统
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "[-] 无法识别系统"
    exit 1
fi

echo "[+] 当前系统: $OS"

SSHD_CONFIG="/etc/ssh/sshd_config"

# 备份
cp $SSHD_CONFIG ${SSHD_CONFIG}.bak_$(date +%F_%T)

echo "[+] 修改 SSH 配置..."

# 设置 root 禁止密码登录（仅允许密钥）
if grep -q "^PermitRootLogin" $SSHD_CONFIG; then
    sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' $SSHD_CONFIG
else
    echo "PermitRootLogin prohibit-password" >> $SSHD_CONFIG
fi

# 确保 PasswordAuthentication 开启（不影响 root，但允许普通用户密码登录）
if grep -q "^PasswordAuthentication" $SSHD_CONFIG; then
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' $SSHD_CONFIG
else
    echo "PasswordAuthentication yes" >> $SSHD_CONFIG
fi

echo "[+] 检查 SSH 配置合法性..."
sshd -t

echo "[+] 重启 SSH 服务..."

# 不同系统服务名不同
if systemctl list-units --type=service | grep -q sshd; then
    systemctl restart sshd
elif systemctl list-units --type=service | grep -q ssh; then
    systemctl restart ssh
else
    echo "[-] 未找到 ssh 服务，请手动重启"
    exit 1
fi

echo "[✓] 完成：root 已禁止密码登录（仅允许密钥）"
