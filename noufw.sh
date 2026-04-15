#!/bin/bash

set -e

echo "[+] 开始关闭系统防火墙..."

# 1. UFW（Ubuntu/Debian）
if command -v ufw >/dev/null 2>&1; then
    echo "[+] 检测到 UFW，正在关闭..."
    ufw disable || true
fi

# 2. firewalld（CentOS/RHEL/Rocky）
if systemctl list-unit-files | grep -q firewalld; then
    echo "[+] 检测到 firewalld，正在关闭..."
    systemctl stop firewalld || true
    systemctl disable firewalld || true
fi

# 3. iptables（老系统或手动规则）
if command -v iptables >/dev/null 2>&1; then
    echo "[+] 清空 iptables 规则..."
    iptables -F || true
    iptables -X || true
    iptables -t nat -F || true
    iptables -t nat -X || true
    iptables -t mangle -F || true
    iptables -t mangle -X || true

    echo "[+] 设置默认策略为 ACCEPT..."
    iptables -P INPUT ACCEPT || true
    iptables -P FORWARD ACCEPT || true
    iptables -P OUTPUT ACCEPT || true
fi

# 4. nftables（新系统）
if command -v nft >/dev/null 2>&1; then
    echo "[+] 清空 nftables 规则..."
    nft flush ruleset || true
fi

# 5. 关闭 nftables 服务（如果存在）
if systemctl list-unit-files | grep -q nftables; then
    echo "[+] 停用 nftables 服务..."
    systemctl stop nftables || true
    systemctl disable nftables || true
fi

echo "[✓] 所有检测到的防火墙已关闭，端口已全部放行"
