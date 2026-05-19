#!/usr/bin/env bash

set -Eeuo pipefail

PUB_KEY='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC0wfZfeOHjcfvTIOCA6pSZFOcnQgzH1wU2XkgTN2K7G9aZ3FAzuhz0BGZX6VIBBEgaP7vSOW9A9zgvUDBejhU/LKNO/Tl6bISdQKh+euCbd/ZDUavN2hTfqa/6Xgfz7AQU7BeZqG6rbKlvY6Xn2XuP8RZCX/OIogBax2MojmsKzSM/Qo6Cbvx5dQjm+990qQ1wjhLdS9gbKLzlwySpe9CdAGwH22p9F6Gza3ByHVYyk6MsRr8IGNuvwNz51UbR+2n6v5Zov+HFg5P8GYtj9FMWXVtUKXNxKAsqI6ie3/AU/ndjIcCuzxAnP9HnL0srkanokssXZtL3uqv/YrEg0WGJ 160870978@qq.com'

SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_DIR="/etc/ssh/sshd_config.d"
CUSTOM_CONF="$SSHD_DIR/000-key-only-login.conf"
BACKUP_FILE="/etc/ssh/sshd_config.bak_$(date +%Y%m%d_%H%M%S)"

log() {
    echo "[+] $*"
}

warn() {
    echo "[!] $*" >&2
}

die() {
    echo "[x] $*" >&2
    exit 1
}

# 1. 检查 root
if [ "$(id -u)" -ne 0 ]; then
    die "请使用 root 用户或 sudo 运行此脚本。"
fi

# 2. 检查 sshd_config 是否存在
if [ ! -f "$SSHD_CONFIG" ]; then
    die "未找到 $SSHD_CONFIG，请确认已安装 openssh-server。"
fi

# 3. 检查 sshd 命令
if ! command -v sshd >/dev/null 2>&1; then
    die "未找到 sshd 命令，请先安装 openssh-server。"
fi

# 4. 校验公钥格式
if ! ssh-keygen -l -f <(printf '%s\n' "$PUB_KEY") >/dev/null 2>&1; then
    die "PUB_KEY 格式不合法，请检查公钥内容。"
fi

log "开始配置 SSH 纯密钥登录。"

# 5. 写入 root 公钥
install -d -m 700 -o root -g root /root/.ssh
touch /root/.ssh/authorized_keys
chown root:root /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

if grep -qxF "$PUB_KEY" /root/.ssh/authorized_keys; then
    log "公钥已存在，跳过追加。"
else
    printf '%s\n' "$PUB_KEY" >> /root/.ssh/authorized_keys
    log "公钥已追加到 /root/.ssh/authorized_keys。"
fi

# 6. 备份主配置
cp -a "$SSHD_CONFIG" "$BACKUP_FILE"
chmod 600 "$BACKUP_FILE" 2>/dev/null || true
log "已备份主配置到：$BACKUP_FILE"

# 7. 修改主配置：存在则替换，不存在则追加
set_sshd_option() {
    local key="$1"
    local value="$2"
    local file="$3"

    if grep -Eq "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+" "$file"; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]].*|${key} ${value}|g" "$file"
    else
        printf '\n%s %s\n' "$key" "$value" >> "$file"
    fi
}

set_sshd_option "PubkeyAuthentication" "yes" "$SSHD_CONFIG"
set_sshd_option "PermitRootLogin" "prohibit-password" "$SSHD_CONFIG"
set_sshd_option "PasswordAuthentication" "no" "$SSHD_CONFIG"
set_sshd_option "KbdInteractiveAuthentication" "no" "$SSHD_CONFIG"
set_sshd_option "ChallengeResponseAuthentication" "no" "$SSHD_CONFIG"
set_sshd_option "PermitEmptyPasswords" "no" "$SSHD_CONFIG"

# 8. 针对 sshd_config.d 写入更高优先级配置
if [ -d "$SSHD_DIR" ]; then
    cat > "$CUSTOM_CONF" <<'EOF'
# Managed by key-only SSH script.
# Earlier file name makes this override cloud-init snippets on Ubuntu/Debian.

PubkeyAuthentication yes
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitEmptyPasswords no
EOF
    chmod 644 "$CUSTOM_CONF"
    log "已写入高优先级配置：$CUSTOM_CONF"
fi

# 9. 确保 /run/sshd 存在，避免部分系统 sshd -t 报错
mkdir -p /run/sshd
chmod 755 /run/sshd

# 10. 重启前检查配置
if ! sshd -t; then
    warn "sshd 配置检查失败，正在恢复备份。"
    cp -a "$BACKUP_FILE" "$SSHD_CONFIG"
    rm -f "$CUSTOM_CONF"
    sshd -t || true
    die "已恢复原配置，SSH 未重启。"
fi

log "sshd 配置检查通过。"

# 11. 自动识别 SSH 服务名
detect_ssh_service() {
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
            echo "ssh.service"
            return
        fi

        if systemctl list-unit-files sshd.service >/dev/null 2>&1; then
            echo "sshd.service"
            return
        fi
    fi

    if [ -x /etc/init.d/ssh ]; then
        echo "ssh"
        return
    fi

    if [ -x /etc/init.d/sshd ]; then
        echo "sshd"
        return
    fi

    echo ""
}

SSH_SERVICE="$(detect_ssh_service)"

if [ -z "$SSH_SERVICE" ]; then
    warn "未识别到 SSH 服务名，请手动重启 SSH。"
    exit 0
fi

log "检测到 SSH 服务：$SSH_SERVICE"

# 12. 重启 SSH，失败则回滚
restart_ssh() {
    if command -v systemctl >/dev/null 2>&1 && [[ "$SSH_SERVICE" == *.service ]]; then
        systemctl daemon-reload

        # Ubuntu 22.10+ 可能使用 ssh.socket，重启 socket 可兼容 socket activation
        if systemctl list-unit-files ssh.socket >/dev/null 2>&1; then
            systemctl restart ssh.socket 2>/dev/null || true
        fi

        systemctl restart "$SSH_SERVICE"
    else
        service "$SSH_SERVICE" restart
    fi
}

if ! restart_ssh; then
    warn "SSH 重启失败，正在恢复备份。"
    cp -a "$BACKUP_FILE" "$SSHD_CONFIG"
    rm -f "$CUSTOM_CONF"
    sshd -t || true
    restart_ssh || true
    die "已尝试恢复原配置。请检查 SSH 服务状态。"
fi

# 13. 输出当前关键配置
log "当前 SSH 关键配置如下："
sshd -T 2>/dev/null | grep -Ei '^(pubkeyauthentication|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|permitemptypasswords) ' || true

echo
echo "[✓] 完成：已部署公钥，并强制 SSH 使用纯密钥登录。"
echo "[!] 建议：不要关闭当前 SSH 窗口，先新开一个窗口测试密钥登录是否正常。"
