#!/bin/bash
# Nezha 启动脚本

export TZ='Asia/Shanghai'
WORK_DIR=/app

# 清理上一轮可能残留的临时目录
rm -rf /tmp/nezha-* 2>/dev/null || true

# 本次实例专用的下载临时目录
DL_TMP="/tmp/nezha-dl-$$"
mkdir -p "$DL_TMP"
trap 'rm -rf "$DL_TMP"' EXIT

# ========== 统一日志 ==========
ts()   { TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S'; }
info() { echo "[$(ts)] [INFO] $*"; }
ok()   { echo "[$(ts)] [ OK ] $*"; }
warn() { echo "[$(ts)] [WARN] $*"; }
fail() { echo "[$(ts)] [FAIL] $*"; }
sub()  { echo "[$(ts)] [INFO]     └─ $*"; }
step() { echo; echo "[$(ts)] [STEP] ===== $* ====="; }
done_(){ echo "[$(ts)] [ OK ] ===== $* ====="; }

# ========== 架构检测 ==========
case $(uname -m) in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    s390x)   ARCH="s390x" ;;
    *)       fail "不支持的架构: $(uname -m)"; exit 1 ;;
esac

# ========== 下载 dashboard / agent ==========
download_agent_dashboard() {
    local dash_file="dashboard-linux-${ARCH}.zip"
    local agent_file="nezha-agent_linux_${ARCH}.zip"

    if [ -z "${DASHBOARD_VERSION:-}" ]; then
        local dash_url="https://github.com/nezhahq/nezha/releases/latest/download/$dash_file"
    else
        local dash_url="https://github.com/nezhahq/nezha/releases/download/$DASHBOARD_VERSION/$dash_file"
    fi

    info "下载 dashboard..."
    if ! wget -q "$dash_url" -O "$DL_TMP/$dash_file"; then
        fail "dashboard 下载失败"
        exit 1
    fi
    if ! unzip -qo "$DL_TMP/$dash_file" -d "$WORK_DIR"; then
        fail "dashboard 解压失败"
        exit 1
    fi
    ok "dashboard 下载完成"

    if [ -n "${NZ_UUID:-}" ] && [ -n "${ARGO_DOMAIN:-}" ]; then
        info "下载 agent..."
        if ! wget -q "https://github.com/nezhahq/agent/releases/latest/download/$agent_file" -O "$DL_TMP/$agent_file"; then
            fail "agent 下载失败"
            exit 1
        fi
        if ! unzip -qo "$DL_TMP/$agent_file" -d "$WORK_DIR"; then
            fail "agent 解压失败"
            exit 1
        fi
        ok "agent 下载完成"
    else
        sub "未设置 NZ_UUID 或 ARGO_DOMAIN，跳过 agent"
    fi
}

# ========== SSL 证书 ==========
setup_ssl() {
    if [ -f "$WORK_DIR/nezha.pem" ] && [ -f "$WORK_DIR/nezha.key" ]; then
        sub "SSL 证书已存在，跳过生成"
        return
    fi
    info "生成自签名 SSL 证书..."
    openssl genrsa -out "$WORK_DIR/nezha.key" 2048
    openssl req -new -key "$WORK_DIR/nezha.key" -out "$WORK_DIR/nezha.csr" -subj "/CN=$ARGO_DOMAIN"
    openssl x509 -req -days 3650 -in "$WORK_DIR/nezha.csr" -signkey "$WORK_DIR/nezha.key" -out "$WORK_DIR/nezha.pem"
    chmod 600 "$WORK_DIR/nezha.key"
    chmod 644 "$WORK_DIR/nezha.pem"
    ok "SSL 证书生成完成"
}

# ========== nginx 配置 ==========
create_nginx_config() {
    cat << 'EOF' > /etc/nginx/conf.d/default.conf
map $http_x_forwarded_for $xff_first_ip {
    default "";
    "~^(?P<first>[^,]+)" $first;
}

map $http_cf_connecting_ip $real_ip {
    default $xff_first_ip;
    "~.+"   $http_cf_connecting_ip;
}

map $real_ip $final_ip {
    default $remote_addr;
    "~.+"   $real_ip;
}

server {
    listen 80;
    http2 on;

    underscores_in_headers on;

    location ^~ /proto.NezhaService/ {
        grpc_set_header Host $host;
        grpc_set_header nz-realip $final_ip;
        grpc_set_header CF-Connecting-IP $final_ip;
        grpc_read_timeout 600s;
        grpc_send_timeout 600s;
        grpc_socket_keepalive on;
        client_max_body_size 10m;
        grpc_buffer_size 4m;
        grpc_pass grpc://dashboard;
    }

    location ~* ^/api/v1/ws/(server|terminal|file)(.*)$ {
        proxy_set_header Host $host;
        proxy_set_header nz-realip $final_ip;
        proxy_set_header CF-Connecting-IP $final_ip;
        proxy_set_header Origin https://$host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass http://127.0.0.1:8008;
    }

    location / {
        proxy_set_header Host $host;
        proxy_set_header nz-realip $final_ip;
        proxy_set_header CF-Connecting-IP $final_ip;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
        proxy_max_temp_file_size 0;
        proxy_pass http://127.0.0.1:8008;
    }
}

upstream dashboard {
    server 127.0.0.1:8008;
    keepalive 2048;
    keepalive_requests 20000;
}
EOF

# ========== 443 端口配置（agent 通过 CF Tunnel 连接） ==========
    cat << SSLEOF > /etc/nginx/conf.d/ssl.conf
server {
    listen 443 ssl;
    http2 on;

    ssl_certificate     $WORK_DIR/nezha.pem;
    ssl_certificate_key $WORK_DIR/nezha.key;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;

    underscores_in_headers on;

    set \$real_ip \$remote_addr;
    if (\$http_x_forwarded_for ~* "^([^,]+)") {
        set \$real_ip \$1;
    }
    if (\$http_x_real_ip) {
        set \$real_ip \$http_x_real_ip;
    }
    if (\$http_cf_connecting_ip) {
        set \$real_ip \$http_cf_connecting_ip;
    }

    location ^~ /proto.NezhaService/ {
        grpc_set_header Host \$host;
        grpc_set_header nz-realip \$real_ip;
        grpc_set_header CF-Connecting-IP \$real_ip;
        grpc_read_timeout 600s;
        grpc_send_timeout 600s;
        grpc_socket_keepalive on;
        client_max_body_size 10m;
        grpc_buffer_size 4m;
        grpc_pass grpc://dashboard;
    }

    location ~* ^/api/v1/ws/(server|terminal|file)(.*)\$ {
        proxy_set_header Host \$host;
        proxy_set_header nz-realip \$real_ip;
        proxy_set_header CF-Connecting-IP \$real_ip;
        proxy_set_header Origin https://\$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass http://127.0.0.1:8008;
    }

    location / {
        proxy_set_header Host \$host;
        proxy_set_header nz-realip \$real_ip;
        proxy_set_header CF-Connecting-IP \$real_ip;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
        proxy_max_temp_file_size 0;
        proxy_pass http://127.0.0.1:8008;
    }
}
SSLEOF
    ok "nginx 配置写入完成"
}

# ========== 优化 nginx 主配置  ==========
# 扛住大量 agent、WebSocket、gRPC 的并发连接
optimize_nginx_main_conf() {
    cat > /etc/nginx/nginx.conf << 'NINXEOF'
user  nginx;
worker_processes  auto;
worker_rlimit_nofile 65535;

error_log  /var/log/nginx/error.log notice;
pid        /run/nginx.pid;

events {
    worker_connections  20480;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile        on;
    keepalive_timeout  65;
    http2_max_concurrent_streams 2048;

    include /etc/nginx/conf.d/*.conf;
}
NINXEOF
    ok "nginx 主配置优化完成"
}

# ========== 环境变量检查 ==========
check_env_variables() {
    if [ -z "${ARGO_DOMAIN:-}" ]; then
        warn "未设置 ARGO_DOMAIN（面板域名/agent域名）无法连接"
    fi
    ok "环境变量检查通过"
}

# ========== 检查 GitHub 是否有备份 ==========
has_backup() {
    if [ -z "${GITHUB_REPO_OWNER:-}" ] || [ -z "${GITHUB_REPO_NAME:-}" ] || [ -z "${GITHUB_TOKEN:-}" ]; then
        return 1
    fi

    local count
    count=$(curl -s --retry 3 --retry-delay 3 \
        -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/repos/$GITHUB_REPO_OWNER/$GITHUB_REPO_NAME/contents?ref=${GITHUB_BRANCH:-main}" \
        | jq -r '.[].name' 2>/dev/null | grep -c '^data-.*\.zip$')

    [ "${count:-0}" -gt 0 ]
}

# ========== 启动基础服务（nginx + cloudflared） ==========
start_nginx_cloudflared() {
    info "启动 nginx..."
    nohup nginx >/dev/null 2>&1 &
    sleep 1

    if [ -n "${ARGO_AUTH:-}" ]; then
        local cf_bin="cloudflared-linux-${ARCH}"
        if [ ! -f "$WORK_DIR/$cf_bin" ]; then
            info "下载 cloudflared..."
            if ! wget -q "https://github.com/cloudflare/cloudflared/releases/latest/download/$cf_bin" -O "$DL_TMP/$cf_bin"; then
                fail "cloudflared 下载失败"
                exit 1
            fi
            chmod +x "$DL_TMP/$cf_bin"
            mv "$DL_TMP/$cf_bin" "$WORK_DIR/$cf_bin"
        fi
        info "启动 cloudflared..."
        TUNNEL_TOKEN="$ARGO_AUTH" nohup ./$cf_bin tunnel --protocol http2 run >/dev/null 2>&1 &
    fi

    ok "nginx + cloudflared 启动完成"
}

# ========== 启动 dashboard ==========
start_dashboard() {
    info "启动 dashboard..."
    nohup ./dashboard-linux-${ARCH} >/dev/null 2>&1 &
    ok "dashboard 启动完成"
}

# ========== 启动 agent ==========
start_agent() {
    # ---- 情况 1：config.yml 存在（从备份恢复） ----
    if [ -f "$WORK_DIR/config.yml" ]; then
        sub "使用现有 config.yml（从备份恢复）"
        info "启动 agent..."
        nohup ./nezha-agent >/dev/null 2>&1 &
        ok "agent 启动完成"
        return
    fi

    # ---- 情况 2：首次安装 ----
    if [ -z "${NZ_UUID:-}" ] || [ -z "${ARGO_DOMAIN:-}" ]; then
        warn "缺少 NZ_UUID / ARGO_DOMAIN，跳过 agent"
        return
    fi

    info "首次安装，生成 agent config.yml..."

    # 从 dashboard 的 data/config.yaml 读 agent_secret_key
    local agent_secret=""
    if [ -f "$WORK_DIR/data/config.yaml" ]; then
        agent_secret=$(grep -E '^agent_secret_key:' "$WORK_DIR/data/config.yaml" \
            | head -n1 | awk '{print $2}' | tr -d '"' | tr -d "'")
    fi

    if [ -z "$agent_secret" ]; then
        warn "未在 data/config.yaml 找到 agent_secret_key，跳过 agent"
        return
    fi
    sub "client_secret 来源: dashboard agent_secret_key"

    cat << EOF > "$WORK_DIR/config.yml"
client_secret: $agent_secret
debug: false
disable_auto_update: true
disable_command_execute: false
disable_force_update: true
disable_nat: false
disable_send_query: false
gpu: false
insecure_tls: false
ip_report_period: 1800
report_delay: 4
server: $ARGO_DOMAIN:443
skip_connection_count: false
skip_procs_count: false
temperature: false
tls: ${NZ_TLS:-true}
use_gitee_to_upgrade: false
use_ipv6_country_code: false
uuid: $NZ_UUID
EOF

    info "启动 agent..."
    nohup ./nezha-agent >/dev/null 2>&1 &
    ok "agent 启动完成"
}

# ========== 打印运行进程 ==========
print_processes() {
    echo
    info "===== 当前运行进程 ====="
    ps -ef 2>/dev/null \
        | sed -E 's/(--token |TUNNEL_TOKEN=)[A-Za-z0-9._-]+/\1***REDACTED***/g' \
        | sed 's/^/    /'
    info "======================="
}

# ========== 主流程 ==========
main() {
    local t0=$(date +%s)

    step "0/6 准备"
    info "架构: $ARCH"
    sub "临时目录: $DL_TMP"

    step "1/6 环境变量检查"
    check_env_variables

    step "2/6 初始化 nginx / SSL"
    setup_ssl
    create_nginx_config
    optimize_nginx_main_conf

    step "3/6 下载 dashboard / agent"
    download_agent_dashboard

    chmod +x "dashboard-linux-${ARCH}"
    [ -f "nezha-agent" ] && chmod +x nezha-agent

    step "4/6 启动 nginx + cloudflared（全程在线）"
    start_nginx_cloudflared

    step "5/6 检查 GitHub 备份"
    if has_backup; then
        info "检测到备份，进入常规启动模式"
        IS_FIRST_INSTALL=0
    else
        info "无备份，进入首次安装模式"
        IS_FIRST_INSTALL=1
    fi

    # ================================================================
    # 分支 1：首次安装
    # ================================================================
    if [ "$IS_FIRST_INSTALL" -eq 1 ]; then
        step "6/6 首次安装"
        start_dashboard

        sub "等待 3 秒让 dashboard 初始化 data 目录..."
        sleep 3

        start_agent

        info "触发首次备份..."
        [ -f "backup.sh" ] && ./backup.sh

    # ================================================================
    # 分支 2：常规启动（dashboard 启动-杀-恢复-重启）
    # ================================================================
    else
        step "6/6 常规启动（恢复数据）"
        start_dashboard

        sub "等待 3 秒让 dashboard 初始化..."
        sleep 3

        # 停止 dashboard，释放数据库
        info "停止 dashboard 释放数据库..."
        pkill -f "dashboard-linux-${ARCH}" 2>/dev/null || true
        sleep 1
        ok "已停止 dashboard"

        # 恢复数据
        if [ -f "restore.sh" ]; then
            ./restore.sh
        else
            warn "未找到 restore.sh，跳过恢复"
        fi

        # 重启 dashboard，加载恢复后的数据
        start_dashboard
        sleep 3

        start_agent
    fi

    local t1=$(date +%s)
    done_ "启动完成 (总耗时 $((t1 - t0))s)"

    print_processes
}

main

# ========== 每小时自动备份/更新检查 ==========
while true; do
    current_date=$(date +"%Y-%m-%d")
    current_hour=$(date +"%H")

    # ---------- 自动备份检查 ----------
    if [ -n "${GITHUB_REPO_OWNER:-}" ] && [ -n "${GITHUB_REPO_NAME:-}" ] && [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${ZIP_PASSWORD:-}" ]; then

        # 用 GitHub API 查最新备份文件（文件名倒排即最新）
        latest_file=$(curl -s --retry 3 --retry-delay 3 \
            -H "Authorization: token $GITHUB_TOKEN" \
            "https://api.github.com/repos/$GITHUB_REPO_OWNER/$GITHUB_REPO_NAME/contents?ref=${GITHUB_BRANCH:-main}" \
            | jq -r '.[].name' | grep '^data-.*\.zip$' | sort -r | head -n1)

        trigger=0
        reason=""

        if [ -z "$latest_file" ]; then
            trigger=1
            reason="仓库中无备份文件"
        else
            # 从文件名提取日期：data-2026-09-17-23-12-10.zip → 2026-09-17
            latest_date=$(echo "$latest_file" | sed -E 's/^data-([0-9]{4}-[0-9]{2}-[0-9]{2})-.*/\1/')
            if [ "$latest_date" != "$current_date" ] && [ "$current_hour" -ge 4 ]; then
                trigger=1
                reason="今日($current_date)未备份，已过 4 点 (当前 ${current_hour} 时)"
            else
                reason="今日已备份或未到 4 点"
            fi
        fi

        if [ "$trigger" -eq 1 ]; then
            info "触发自动备份: $reason"
            [ -f "backup.sh" ] && ./backup.sh
        else
            sub "跳过备份: $reason"
        fi
    fi

    # ---------- 版本更新检查 ----------
    # 设置了 DASHBOARD_VERSION 就锁定版本，跳过更新检查
    if [ -z "${DASHBOARD_VERSION:-}" ]; then
        [ -f "renew.sh" ] && ./renew.sh
    else
        sub "已锁定版本 $DASHBOARD_VERSION，跳过更新检查"
    fi

    sleep 3600
done
