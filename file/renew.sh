#!/bin/bash
# Nezha 自动更新脚本
set -u

ts()   { TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S'; }
info() { echo "[$(ts)] [INFO] $*"; }
ok()   { echo "[$(ts)] [ OK ] $*"; }
warn() { echo "[$(ts)] [WARN] $*"; }
sub()  { echo "[$(ts)] [INFO]     └─ $*"; }

WORK_DIR=/app
cd "$WORK_DIR" || { warn "无法进入 $WORK_DIR"; exit 1; }

# 本次运行专用的临时目录（不与其它脚本冲突）
DL_TMP="/tmp/nezha-renew-$$"
mkdir -p "$DL_TMP"
trap 'rm -rf "$DL_TMP"' EXIT

case $(uname -m) in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    s390x)   ARCH="s390x" ;;
    *)       warn "不支持的架构"; exit 1 ;;
esac

get_local_version() {
    case "$1" in
        dashboard) ./dashboard-linux-${ARCH} -v 2>/dev/null | grep -oE '[0-9.]+' ;;
        agent)     ./nezha-agent -v 2>/dev/null | grep -oE '[0-9.]+' ;;
    esac
}

get_remote_version() {
    # 用 jq 解析 tag_name，去掉前缀 v，避免 beta/rc 误判
    curl -sL "https://api.github.com/repos/$1/releases/latest" | jq -r '.tag_name // empty' | sed 's/^v//'
}

update_component() {
    local repo="$1" filename="$2" component="$3"
    local local_ver remote_ver
    local_ver=$(get_local_version "$component")
    remote_ver=$(get_remote_version "$repo")

    [ -z "$remote_ver" ] && return 1
    [ "$local_ver" = "$remote_ver" ] && return 1

    info "更新 $component: ${local_ver:-未知} -> $remote_ver"
    if ! wget -q "https://github.com/$repo/releases/latest/download/$filename" -O "$DL_TMP/$filename"; then
        warn "$component 下载失败，跳过"
        return 1
    fi
    if ! unzip -qo "$DL_TMP/$filename" -d "$WORK_DIR"; then
        warn "$component 解压失败，跳过"
        return 1
    fi
    return 0
}

info "检查更新..."
updated=0

update_component "nezhahq/nezha" "dashboard-linux-${ARCH}.zip" "dashboard" && updated=1 || true
update_component "nezhahq/agent" "nezha-agent_linux_${ARCH}.zip" "agent" && updated=1 || true

if [ "$updated" -eq 1 ]; then
    chmod +x dashboard-linux-${ARCH} nezha-agent 2>/dev/null || true
    info "重启服务..."
    pkill -f "dashboard-linux-${ARCH}|nezha-agent" 2>/dev/null || true
    sleep 1
    nohup ./dashboard-linux-${ARCH} >/dev/null 2>&1 &
    nohup ./nezha-agent >/dev/null 2>&1 &
    ok "更新完成"
else
    sub "已是最新版本"
fi
