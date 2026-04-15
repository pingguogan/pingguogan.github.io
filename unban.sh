#!/bin/bash

set -e

# 1. 检查是否为 root 用户运行
if [ "$(id -u)" -ne 0 ]; then
    echo "[!] 错误: 请使用 root 用户或 sudo 运行此脚本。"
    exit 1
fi

echo "[+] 开始恢复 SSH 密码登录..."

# 2. 尝试解除配置文件的底层锁定 (针对 1Panel 等防篡改机制)
echo "[+] 尝试解除配置文件的系统锁定..."
chattr -i /etc/ssh/sshd_config 2>/dev/null || true
chattr -a /etc/ssh/sshd_config 2>/dev/null || true

# 3. 自动识别系统发行版以确定 SSH 服务名称
SSH_SERVICE="sshd" 
if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
        ubuntu|debian|linuxmint|kali)
            SSH_SERVICE="ssh"
            ;;
    esac
fi

# 4. 备份主配置
BACKUP_FILE="/etc/ssh/sshd_config.bak_enable_pwd_$(date +%Y%m%d_%H%M%S)"
cp /etc/ssh/sshd_config "$BACKUP_FILE"
echo "[+] 已备份当前配置至: $BACKUP_FILE"

# 5. 修改主配置文件 (全面恢复密码权限)
echo "[+] 正在修改主配置文件..."
# 允许 root 密码登录
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
# 开启密码和各种交互式认证
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/' /etc/ssh/sshd_config

# 确保 PasswordAuthentication 这一行真实存在，防止被意外删干净
if ! grep -q "^PasswordAuthentication yes" /etc/ssh/sshd_config; then
    echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
fi

# 6. 删除之前创建的高优先级禁用文件
if [ -f "/etc/ssh/sshd_config.d/00-disable-pwd.conf" ]; then
    echo "[+] 检测到高级覆盖规则文件，正在清理..."
    rm -f /etc/ssh/sshd_config.d/00-disable-pwd.conf
fi

# 7. 确定并执行重启命令
echo "[+] 正在重启 $SSH_SERVICE 服务..."
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl restart ${SSH_SERVICE}.socket ${SSH_SERVICE}.service 2>/dev/null || systemctl restart ${SSH_SERVICE}
elif command -v service >/dev/null 2>&1; then
    service "$SSH_SERVICE" restart
elif [ -x "/etc/init.d/$SSH_SERVICE" ]; then
    "/etc/init.d/$SSH_SERVICE" restart
else
    echo "[!] 警告: 未能自动找到重启命令，请手动重启 SSH 服务。"
fi

echo "[✓] 恢复完成：服务器已重新开启密码登录（包含 root 用户）！"
echo "[i] 提示: 如果需要恢复面板的防篡改锁定，可手动执行: chattr +i /etc/ssh/sshd_config"
