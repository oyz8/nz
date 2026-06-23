#!/bin/sh

# =========================
# 环境变量
# =========================
ARGO_DOMAIN=${ARGO_DOMAIN:-""}
ARGO_AUTH=${ARGO_AUTH:-""}
NZ_UUID=${NZ_UUID:-""}
NZ_CLIENT_SECRET=${NZ_CLIENT_SECRET:-""}
NZ_TLS=${NZ_TLS:-true}
DASHBOARD_VERSION=${DASHBOARD_VERSION:-latest}

GITHUB_REPO_OWNER=${GITHUB_REPO_OWNER:-""}
GITHUB_REPO_NAME=${GITHUB_REPO_NAME:-""}
GITHUB_TOKEN=${GITHUB_TOKEN:-""}
GITHUB_BRANCH=${GITHUB_BRANCH:-main}
ZIP_PASSWORD=${ZIP_PASSWORD:-""}

PROJECT_URL=${PROJECT_URL:-""}

# =========================
# 日志函数
# =========================
log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_ok() {
    echo "[OK] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_warn() {
    echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

# =========================
# 保活函数
# =========================
add_visit_task() {
    if [ -z "$PROJECT_URL" ]; then
        log_info "跳过自动保活任务"
        return 0
    fi
    
    if curl -s -X POST "https://trans.ct8.pl/add-url" \
        -H "Content-Type: application/json" \
        -d "{\"url\":\"$PROJECT_URL\"}" >/dev/null; then
        log_ok "自动保活任务添加成功"
    else
        log_error "添加自动保活任务失败"
    fi
}

# =========================
# 端口等待函数（使用 curl 检测 HTTP 服务）
# =========================
wait_for_port() {
    local port=$1
    local max_wait=${2:-60}
    local count=0
    
    log_info "等待端口 $port 就绪 (超时: ${max_wait}s)"
    while [ $count -lt $max_wait ]; do
        if curl -s http://127.0.0.1:$port > /dev/null 2>&1; then
            log_ok "端口 $port 已就绪"
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done
    log_error "端口 $port 等待超时"
    return 1
}

# =========================
# 步骤 1: 启动 Nginx (健康检查端口 7860)
# =========================
echo "=========================================="
echo " 步骤 1: 启动 Nginx (端口 7860)"
echo "=========================================="

rm -f /etc/nginx/conf.d/default.conf
nginx
sleep 1

if curl -s http://127.0.0.1:7860 > /dev/null 2>&1; then
    log_ok "Nginx 端口 7860 已就绪"
else
    log_warn "Nginx 端口 7860 检查失败"
fi

# =========================
# 步骤 2: 恢复备份
# =========================
echo "=========================================="
echo " 步骤 2: 恢复备份"
echo "=========================================="

RESTORE_SUCCESS=false
if /restore.sh; then
    log_ok "备份恢复成功"
    RESTORE_SUCCESS=true
else
    log_warn "无可用备份，继续启动"
fi

# =========================
# 步骤 3: 启动 cron
# =========================
log_info "启动 cron 服务"
cron

# =========================
# 步骤 3.5: 生成面板配置（首次部署）
# =========================
if [ "$RESTORE_SUCCESS" = "false" ]; then
    echo "=========================================="
    echo " 步骤 3.5: 生成面板配置（首次部署）"
    echo "=========================================="
    
    mkdir -p /dashboard/data
    JWT_SECRET=$(head -c 512 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 512)
    NZ_CLIENT_SECRET=${NZ_CLIENT_SECRET:-$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)}
    NZ_UUID=${NZ_UUID:-$(cat /proc/sys/kernel/random/uuid)}
    
    cat > /dashboard/data/config.yaml <<EOF
admin_template: admin-dist
agent_secret_key: $NZ_CLIENT_SECRET
avg_ping_count: 2
cover: 1
https: {}
ip_change_notification_group_id: 0
jwt_secret_key: $JWT_SECRET
jwt_timeout: 1
language: zh_CN
listen_port: 8008
location: Asia/Shanghai
site_name: 哪吒监控
tls: ${NZ_TLS:-true}
user_template: user-dist
EOF
    log_ok "面板配置已生成"
    log_info "NZ_UUID=$NZ_UUID"
    log_info "NZ_CLIENT_SECRET=$NZ_CLIENT_SECRET"
fi

# =========================
# 步骤 3.6: 提升系统限制 + 面板高并发参数
# =========================
echo "=========================================="
echo " 步骤 3.6: 优化系统限制 & 面板参数"
echo "=========================================="

ulimit -n 65536 2>/dev/null || true
log_info "文件描述符限制已尝试提升至 65536"

if [ -f /dashboard/data/config.yaml ]; then
    grep -q 'max_agent_conn' /dashboard/data/config.yaml || echo 'max_agent_conn: 2000' >> /dashboard/data/config.yaml
    grep -q 'grpc_max_concurrent_streams' /dashboard/data/config.yaml || echo 'grpc_max_concurrent_streams: 2000' >> /dashboard/data/config.yaml
    grep -q 'grpc_max_conn_age' /dashboard/data/config.yaml || echo 'grpc_max_conn_age: 0' >> /dashboard/data/config.yaml
    grep -q 'grpc_keepalive_time' /dashboard/data/config.yaml || echo 'grpc_keepalive_time: 10s' >> /dashboard/data/config.yaml
    grep -q 'grpc_keepalive_timeout' /dashboard/data/config.yaml || echo 'grpc_keepalive_timeout: 5s' >> /dashboard/data/config.yaml
    log_ok "面板高并发参数已补丁"
fi

# =========================
# 步骤 4: 启动面板
# =========================
echo "=========================================="
echo " 步骤 4: 启动面板"
echo "=========================================="

./app > /dev/null 2>&1 &
APP_PID=$!
log_info "面板已启动 (PID: $APP_PID)"

if ! wait_for_port 8008 60; then
    log_error "面板启动失败"
    exit 1
fi

sleep 3
log_ok "面板已完全就绪"

# =========================
# 步骤 5: 生成 SSL 证书
# =========================
if [ -n "$ARGO_DOMAIN" ]; then
    echo "=========================================="
    echo " 步骤 5: 生成 SSL 证书"
    echo "=========================================="
    
    log_info "生成证书: $ARGO_DOMAIN"
    openssl genrsa -out /dashboard/nezha.key 2048 2>/dev/null
    openssl req -new -subj "/CN=$ARGO_DOMAIN" -key /dashboard/nezha.key -out /dashboard/nezha.csr 2>/dev/null
    openssl x509 -req -days 36500 -in /dashboard/nezha.csr -signkey /dashboard/nezha.key -out /dashboard/nezha.pem 2>/dev/null
    
    sed "s/ARGO_DOMAIN_PLACEHOLDER/$ARGO_DOMAIN/g" /etc/nginx/ssl.conf.template > /etc/nginx/conf.d/ssl.conf
    
    nginx -s reload
    sleep 1
    log_ok "证书生成完成，443 端口已启用"
else
    log_warn "未设置 ARGO_DOMAIN，跳过证书生成"
fi

# =========================
# 步骤 6: 启动 cloudflared（动态库方式）
# =========================
if [ -n "$ARGO_AUTH" ]; then
    echo "=========================================="
    echo " 步骤 6: 启动 cloudflared (动态库)"
    echo "=========================================="
    
    python3 /start_cloudflared.py > /dev/null 2>&1 &
    sleep 5
    
    if pgrep -f "python3 /start_cloudflared.py" >/dev/null; then
        log_ok "cloudflared 启动成功"
    else
        log_error "cloudflared 启动失败"
    fi
else
    log_warn "未设置 ARGO_AUTH，跳过 cloudflared"
fi

# =========================
# 步骤 7: 启动探针（动态库方式）
# =========================
if [ -n "$ARGO_DOMAIN" ]; then
    echo "=========================================="
    echo " 步骤 7: 启动探针 (动态库)"
    echo "=========================================="
    
    log_info "等待隧道建立"
    sleep 5
    
    AGENT_SECRET=$(grep '^agent_secret_key:' /dashboard/data/config.yaml | awk '{print $2}')
    NZ_UUID=${NZ_UUID:-$(cat /proc/sys/kernel/random/uuid)}
    
    if [ -z "$AGENT_SECRET" ]; then
        log_error "无法获取 agent_secret_key"
    else
        cat > /dashboard/config.yaml <<EOF
client_secret: $AGENT_SECRET
debug: true
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
tls: $NZ_TLS
use_gitee_to_upgrade: false
use_ipv6_country_code: false
uuid: $NZ_UUID
EOF

        log_info "探针配置: server=$ARGO_DOMAIN:443, tls=$NZ_TLS, uuid=$NZ_UUID"
        
        python3 /start_agent.py /dashboard/config.yaml > /dev/null 2>&1 &
        AGENT_PID=$!
        sleep 3
        
        if pgrep -f "python3 /start_agent.py" >/dev/null; then
            log_ok "探针启动成功 (PID: $AGENT_PID)"
        else
            log_error "探针启动失败"
        fi
    fi
else
    log_warn "未设置 ARGO_DOMAIN，跳过探针"
fi

# =========================
# 步骤 8: 启动备份守护进程
# =========================
if [ -n "$GITHUB_TOKEN" ] && [ -n "$GITHUB_REPO_OWNER" ] && [ -n "$GITHUB_REPO_NAME" ]; then
    echo "=========================================="
    echo " 步骤 8: 启动备份守护进程"
    echo "=========================================="
    
    (
        API_BASE="https://api.github.com/repos/$GITHUB_REPO_OWNER/$GITHUB_REPO_NAME"
        BACKUP_HOUR=${BACKUP_HOUR:-4}
        
        while true; do
            current_date=$(date +"%Y-%m-%d")
            current_hour=$(date +"%H")
            
            readme_content=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
                "$API_BASE/contents/README.md?ref=$GITHUB_BRANCH" \
                | jq -r '.content' 2>/dev/null | base64 -d 2>/dev/null | tr -d '[:space:]' || echo "")
            
            should_backup=false
            backup_reason=""
            
            if [ "$readme_content" = "backup" ]; then
                should_backup=true
                backup_reason="手动触发"
            else
                latest_backup=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
                    "$API_BASE/contents?ref=$GITHUB_BRANCH" \
                    | jq -r '.[].name' 2>/dev/null | grep '^data-.*\.zip$' | sort -r | head -n1)
                file_date=$(echo "$latest_backup" | sed -n 's/^data-\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)-.*\.zip$/\1/p')
                
                if [ "$current_hour" -eq "$BACKUP_HOUR" ] && [ "$file_date" != "$current_date" ]; then
                    should_backup=true
                    backup_reason="定时备份 (${BACKUP_HOUR}:00)"
                fi
            fi
            
            if [ "$should_backup" = "true" ]; then
                echo "$(date): 触发备份 - $backup_reason"
                [ -f "/backup.sh" ] && /backup.sh
            fi
            
            sleep 3600
        done
    ) &
    
    log_ok "备份守护进程已启动"
else
    log_warn "GITHUB_TOKEN & GITHUB_REPO_NAME & GITHUB_REPO_OWNER 未设置，跳过备份"
fi

# =========================
# 步骤 9: 添加保活任务
# =========================
echo "=========================================="
echo " 步骤 9: 添加保活任务"
echo "=========================================="

add_visit_task

# =========================
# 启动完成
# =========================
echo "=========================================="
echo " 启动完成"
echo "=========================================="
echo " 访问地址: https://$ARGO_DOMAIN"
echo "=========================================="

echo ""
echo "运行中的进程:"
ps aux | grep -E "(app|python3|nginx)" | grep -v grep

echo ""
log_info "启动健康检查..."

# =========================
# 健康检查循环（所有重启日志均丢弃）
# =========================
while true; do
    if ! pgrep -x "app" >/dev/null; then
        ./app > /dev/null 2>&1 &
        log_warn "面板已重启"
    fi
    
    if [ -n "$ARGO_AUTH" ] && ! pgrep -f "python3 /start_cloudflared.py" >/dev/null; then
        python3 /start_cloudflared.py > /dev/null 2>&1 &
        log_warn "cloudflared 已重启"
    fi

    if ! pgrep -x "nginx" >/dev/null; then
        nginx
        log_warn "nginx 已重启"
    fi

    if [ -n "$ARGO_DOMAIN" ] && [ -f /dashboard/config.yaml ] && ! pgrep -f "python3 /start_agent.py" >/dev/null; then
        python3 /start_agent.py /dashboard/config.yaml > /dev/null 2>&1 &
        log_warn "探针已重启"
    fi

    sleep 60
done
