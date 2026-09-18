#!/bin/bash
# Nezha 重启脚本

ts()   { TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S'; }
info() { echo "[$(ts)] [INFO] $*"; }
ok()   { echo "[$(ts)] [ OK ] $*"; }

case $(uname -m) in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    s390x)   ARCH="s390x" ;;
    *)       ARCH="amd64" ;;
esac

info "停止 dashboard..."
pkill -f "dashboard-linux-${ARCH}" 2>/dev/null || true
sleep 1

info "启动 dashboard..."
nohup ./dashboard-linux-${ARCH} >/dev/null 2>&1 &
sleep 2

ok "dashboard 已重启"
