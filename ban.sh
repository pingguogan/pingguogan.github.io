#!/bin/bash

set -e

# 1. 检查是否为 root 用户运行
if [ "$(id -u)" -ne 0 ]; then
    echo "[!] 错误: 请使用 root 用户或 sudo 运行此脚本。"
    exit 1
fi

echo "[+] 开始配置 SSH 纯密钥登录..."

# 2. 自动识别系统发行版以确定 SSH 服务名称
SSH_SERVICE="sshd" # 默认大多数系统 (CentOS, RHEL, Fedora, Arch, Alpine 等) 都是 sshd
if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
        ubuntu|debian|linuxmint|kali)
            SSH_SERVICE="ssh"
            ;;
    esac
fi
echo "[+] 检测到系统: ${PRETTY_NAME:-Unknown}，SSH 服务名为: $SSH_SERVICE"

# 3. 备份主配置 (加上时间戳防覆盖)
BACKUP_FILE="/etc/ssh/sshd_config.bak_$(date +%Y%m%d_%H%M%S)"
cp /etc/ssh/sshd_config "$BACKUP_FILE"
echo "[+] 已备份主配置至: $BACKUP_FILE"

# 4. 修改主配置文件 (兼容所有新老系统)
# 设置 root 仅允许密钥登录
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
# 彻底关闭密码和各种交互式认证
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config

# 5. 处理高优先级配置 (专门针对带有云初始化覆盖的现代系统，如 Ubuntu 22.04+)
if [ -d "/etc/ssh/sshd_config.d" ]; then
    echo "[+] 检测到 sshd_config.d 目录，写入最高优先级规则..."
    echo -e "PasswordAuthentication no\nKbdInteractiveAuthentication no" > /etc/ssh/sshd_config.d/00-disable-pwd.conf
fi

# 6. 确定并执行重启命令 (兼容不同系统的服务管理器)
echo "[+] 正在重启 $SSH_SERVICE 服务..."
if command -v systemctl >/dev/null 2>&1; then
    # 现代 Systemd 系统
    systemctl daemon-reload
    # 尝试同时重启 socket 和 service，如果系统不支持 socket 则回退到普通重启
    systemctl restart ${SSH_SERVICE}.socket ${SSH_SERVICE}.service 2>/dev/null || systemctl restart ${SSH_SERVICE}
elif command -v service >/dev/null 2>&1; then
    # 传统的 SysVinit 系统
    service "$SSH_SERVICE" restart
elif [ -x "/etc/init.d/$SSH_SERVICE" ]; then
    # 更古老的系统
    "/etc/init.d/$SSH_SERVICE" restart
else
    echo "[!] 警告: 未能自动找到重启命令，请手动重启 SSH 服务。"
fi

echo "[✓] 已完成：全站已强制修改为纯密钥登录，彻底禁用密码！"
