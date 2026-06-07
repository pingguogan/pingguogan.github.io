#!/usr/bin/env bash

set -Eeuo pipefail

# ==========================================
# 请替换为你的实际公钥
PUB_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILh+uor82B1VQyCbg3M0U1qBVmC7Xuaqds7E8OAv14JM'
# ==========================================

SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_DIR="/etc/ssh/sshd_config.d"
BACKUP_FILE="/etc/ssh/sshd_config.bak_$(date +%Y%m%d_%H%M%S)"

log() { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*" >&2; }
die() { echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }

# 1. 前置检查
if [ "$(id -u)" -ne 0 ]; then
    die "请使用 root 用户或 sudo 运行此脚本。"
fi

if ! command -v sshd >/dev/null 2>&1 || [ ! -f "$SSHD_CONFIG" ]; then
    die "未找到 sshd 命令或 $SSHD_CONFIG 配置，请确认已安装 OpenSSH 服务端。"
fi

if ! ssh-keygen -l -f <(printf '%s\n' "$PUB_KEY") >/dev/null 2>&1; then
    die "PUB_KEY 格式不合法，请检查公钥内容。"
fi

log "开始配置 SSH 纯密钥登录 (跨发行版适配模式)..."

# 2. 写入 root 公钥
install -d -m 700 -o root -g root /root/.ssh
touch /root/.ssh/authorized_keys
chown root:root /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

if grep -qF "$PUB_KEY" /root/.ssh/authorized_keys; then
    log "公钥已存在，跳过追加。"
else
    printf '%s\n' "$PUB_KEY" >> /root/.ssh/authorized_keys
    log "公钥已追加到 /root/.ssh/authorized_keys。"
fi

# 3. 备份主配置
cp -a "$SSHD_CONFIG" "$BACKUP_FILE"
chmod 600 "$BACKUP_FILE" 2>/dev/null || true
log "已备份主配置到：$BACKUP_FILE"

# 4. 核心配置修改函数
set_sshd_option() {
    local key="$1"
    local value="$2"
    local file="$3"

    # 如果存在被注释的或现有的项，替换它；否则追加
    if grep -Eq "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+" "$file"; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]].*|${key} ${value}|g" "$file"
    else
        printf '\n%s %s\n' "$key" "$value" >> "$file"
    fi
}

# 动态测试并应用配置 (兼容不同 OpenSSH 版本)
test_and_set_sshd_option() {
    local key="$1"
    local val="$2"
    local file="$3"
    
    # 开启一个测试实例，检查该 OpenSSH 版本是否认识这个参数
    if sshd -t -o "${key}=${val}" >/dev/null 2>&1; then
        set_sshd_option "$key" "$val" "$file"
    fi
}

# 5. 修改主配置文件
# 通用标准配置
set_sshd_option "PubkeyAuthentication" "yes" "$SSHD_CONFIG"
set_sshd_option "PasswordAuthentication" "no" "$SSHD_CONFIG"
set_sshd_option "PermitEmptyPasswords" "no" "$SSHD_CONFIG"

# 动态兼容: OpenSSH < 7.0 使用 without-password, 7.0+ 使用 prohibit-password
if sshd -t -o "PermitRootLogin=prohibit-password" >/dev/null 2>&1; then
    set_sshd_option "PermitRootLogin" "prohibit-password" "$SSHD_CONFIG"
else
    set_sshd_option "PermitRootLogin" "without-password" "$SSHD_CONFIG"
fi

# 动态兼容: KbdInteractive 是主流，ChallengeResponse 在 OpenSSH 9+ 被废弃
test_and_set_sshd_option "KbdInteractiveAuthentication" "no" "$SSHD_CONFIG"
test_and_set_sshd_option "ChallengeResponseAuthentication" "no" "$SSHD_CONFIG"

# 6. 处理 sshd_config.d 目录 (如果主配置中启用了 Include)
if grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$SSHD_CONFIG" && [ -d "$SSHD_DIR" ]; then
    CUSTOM_CONF="$SSHD_DIR/000-key-only-login.conf"
    cat > "$CUSTOM_CONF" <<EOF
# Managed by cross-distro key-only SSH script.
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
EOF
    # 动态追加支持的字段
    sshd -t -o "PermitRootLogin=prohibit-password" >/dev/null 2>&1 && echo "PermitRootLogin prohibit-password" >> "$CUSTOM_CONF" || echo "PermitRootLogin without-password" >> "$CUSTOM_CONF"
    sshd -t -o "KbdInteractiveAuthentication=no" >/dev/null 2>&1 && echo "KbdInteractiveAuthentication no" >> "$CUSTOM_CONF"
    sshd -t -o "ChallengeResponseAuthentication=no" >/dev/null 2>&1 && echo "ChallengeResponseAuthentication no" >> "$CUSTOM_CONF"
    
    chmod 644 "$CUSTOM_CONF"
    log "已写入 Include 子目录配置：$CUSTOM_CONF"
fi

# 7. 修复 SELinux 上下文 (针对 RHEL/CentOS/Alma/Rocky 家族)
if command -v restorecon >/dev/null 2>&1; then
    restorecon "$SSHD_CONFIG" 2>/dev/null || true
    [ -n "${CUSTOM_CONF:-}" ] && restorecon "$CUSTOM_CONF" 2>/dev/null || true
    log "已检查并修复 SELinux 文件上下文。"
fi

# 8. 确保 /run/sshd 存在
mkdir -p /run/sshd && chmod 755 /run/sshd

# 9. 重启前配置语法校验
if ! sshd -t; then
    warn "sshd 配置语法检查失败，正在回滚配置..."
    cp -a "$BACKUP_FILE" "$SSHD_CONFIG"
    [ -n "${CUSTOM_CONF:-}" ] && rm -f "$CUSTOM_CONF"
    die "已恢复原配置。脚本意外中止，请手动检查 sshd -t 报错。"
fi
log "sshd 配置语法检查通过。"

# 10. 智能探测 Init 系统与 SSH 服务名
detect_and_restart_ssh() {
    # 策略 1: Systemd (Ubuntu, Debian, RHEL 7+, Arch, etc.)
    if command -v systemctl >/dev/null 2>&1; then
        local svc=""
        # 寻找正确的服务名
        if systemctl list-unit-files sshd.service >/dev/null 2>&1 || systemctl is-active sshd.service >/dev/null 2>&1; then
            svc="sshd.service"
        elif systemctl list-unit-files ssh.service >/dev/null 2>&1 || systemctl is-active ssh.service >/dev/null 2>&1; then
            svc="ssh.service"
        fi

        if [ -n "$svc" ]; then
            log "检测到 Init 系统为 Systemd，守护进程为 $svc"
            systemctl daemon-reload
            
            # 兼容 Socket 激活模式 (如 Ubuntu 24.04/26.04)
            local sock="${svc%%.service}.socket"
            if systemctl list-unit-files "$sock" >/dev/null 2>&1 && systemctl is-enabled "$sock" >/dev/null 2>&1; then
                log "触发 Systemd Socket 激活机制，重启 $sock"
                systemctl restart "$sock"
                systemctl stop "$svc" 2>/dev/null || true
            else
                systemctl restart "$svc"
            fi
            return 0
        fi
    fi

    # 策略 2: OpenRC (Alpine Linux 等)
    if command -v rc-service >/dev/null 2>&1 && rc-service sshd status >/dev/null 2>&1; then
        log "检测到 Init 系统为 OpenRC"
        rc-service sshd restart
        return 0
    fi

    # 策略 3: SysVinit / Upstart (老旧系统 / 容器化环境)
    if [ -x /etc/init.d/sshd ]; then
        log "检测到 Init 系统为 SysVinit (sshd)"
        /etc/init.d/sshd restart
        return 0
    elif [ -x /etc/init.d/ssh ]; then
        log "检测到 Init 系统为 SysVinit (ssh)"
        /etc/init.d/ssh restart
        return 0
    fi

    return 1
}

if ! detect_and_restart_ssh; then
    warn "SSH 重启失败，正在尝试回滚备份..."
    cp -a "$BACKUP_FILE" "$SSHD_CONFIG"
    [ -n "${CUSTOM_CONF:-}" ] && rm -f "$CUSTOM_CONF"
    detect_and_restart_ssh || true
    die "未能自动识别 Init 系统或重启失败，请检查机器状态。"
fi

log "当前 SSH 关键安全策略验证如下："
sshd -T 2>/dev/null | grep -Ei '^(pubkeyauthentication|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|permitemptypasswords|challengeresponseauthentication) ' || true

echo
echo -e "\033[1;32m[✓] 部署完成：已强制 SSH 使用纯密钥登录。\033[0m"
echo -e "\033[1;33m[!] 高危警告：请勿关闭当前终端！立即新开一个 SSH 窗口，测试使用密钥登录是否成功。\033[0m"
