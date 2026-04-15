#!/bin/bash

set -e

# 1. 检查是否为 root 用户运行
if [ "$(id -u)" -ne 0 ]; then
    echo "[!] 错误: 请使用 root 用户或 sudo 运行此脚本。"
    exit 1
fi

echo "[+] 开始配置 SSH 纯密钥登录并写入公钥..."

# 2. 自动注入你的公钥
PUB_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC0wfZfeOHjcfvTIOCA6pSZFOcnQgzH1wU2XkgTN2K7G9aZ3FAzuhz0BGZX6VIBBEgaP7vSOW9A9zgvUDBejhU/LKNO/Tl6bISdQKh+euCbd/ZDUavN2hTfqa/6Xgfz7AQU7BeZqG6rbKlvY6Xn2XuP8RZCX/OIogBax2MojmsKzSM/Qo6Cbvx5dQjm+990qQ1wjhLdS9gbKLzlwySpe9CdAGwH22p9F6Gza3ByHVYyk6MsRr8IGNuvwNz51UbR+2n6v5Zov+HFg5P8GYtj9FMWXVtUKXNxKAsqI6ie3/AU/ndjIcCuzxAnP9HnL0srkanokssXZtL3uqv/YrEg0WGJ 160870978@qq.com"

# 确保 /root/.ssh 目录存在并设置正确权限
mkdir -p /root/.ssh
chmod 700 /root/.ssh

# 检查公钥是否已存在，不存在则追加
if ! grep -qF "160870978@qq.com" /root/.ssh/authorized_keys 2>/dev/null; then
    echo "$PUB_KEY" >> /root/.ssh/authorized_keys
    echo "[+] 公钥已成功追加到 /root/.ssh/authorized_keys"
else
    echo "[-] 公钥已存在，跳过追加。"
fi
# 确保文件权限正确
chmod 600 /root/.ssh/authorized_keys


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
echo "[+] 检测到系统: ${PRETTY_NAME:-Unknown}，SSH 服务名为: $SSH_SERVICE"

# 4. 备份主配置 (加上时间戳防覆盖)
BACKUP_FILE="/etc/ssh/sshd_config.bak_$(date +%Y%m%d_%H%M%S)"
cp /etc/ssh/sshd_config "$BACKUP_FILE"
echo "[+] 已备份主配置至: $BACKUP_FILE"

# 5. 修改主配置文件 (兼容所有新老系统)
# 设置 root 仅允许密钥登录
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
# 彻底关闭密码和各种交互式认证
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config

# 6. 处理高优先级配置 (专门针对带有云初始化覆盖的现代系统)
if [ -d "/etc/ssh/sshd_config.d" ]; then
    echo "[+] 检测到 sshd_config.d 目录，写入最高优先级禁用规则..."
    echo -e "PasswordAuthentication no\nKbdInteractiveAuthentication no" > /etc/ssh/sshd_config.d/00-disable-pwd.conf
fi

# 7. 确定并执行重启命令 (兼容不同系统的服务管理器)
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

echo "[✓] 完美结束：你的公钥已部署，且服务器已强制切换为纯密钥登录！"
