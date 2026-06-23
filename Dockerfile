# ==========================
# 运行阶段：Nginx + 工具环境（基于 Debian）
# ==========================
FROM nginx:latest

# 更新源并安装依赖（含 cron）
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        wget \
        unzip \
        bash \
        curl \
        git \
        tar \
        openssl \
        jq \
        procps \
        tzdata \
        zip \
        sqlite3 \
        libsqlite3-dev \
        python3 \
        python3-requests \
        ca-certificates \
        cron && \
    rm -rf /var/lib/apt/lists/*

# Nginx 配置
COPY nginx.conf /etc/nginx/nginx.conf
COPY main.conf /etc/nginx/conf.d/main.conf
RUN rm -f /etc/nginx/conf.d/default.conf
COPY ssl.conf.template /etc/nginx/ssl.conf.template

# 时区
ENV TZ=Asia/Shanghai

# 工作目录
WORKDIR /dashboard

# 下载哪吒面板（自动适配当前构建架构）
ARG TARGETARCH=amd64
ARG DASHBOARD_VERSION=latest
RUN if [ "$DASHBOARD_VERSION" = "latest" ]; then \
        DASHBOARD_VERSION=$(curl -s https://api.github.com/repos/nezhahq/nezha/releases/latest \
            | jq -r .tag_name); \
    fi && \
    echo "Dashboard version: $DASHBOARD_VERSION  arch: $TARGETARCH" && \
    wget -q "https://github.com/nezhahq/nezha/releases/download/${DASHBOARD_VERSION}/dashboard-linux-${TARGETARCH}.zip" \
        -O /tmp/dashboard.zip && \
    unzip -qo /tmp/dashboard.zip -d /tmp/dashboard && \
    mv /tmp/dashboard/dashboard-linux-${TARGETARCH} /dashboard/app && \
    chmod +x /dashboard/app && \
    rm -rf /tmp/dashboard /tmp/dashboard.zip

# 数据目录并设置权限
RUN mkdir -p /dashboard/data && chmod -R 777 /dashboard

# 暴露端口
EXPOSE 8008

# 环境变量（敏感信息建议运行时注入）
ENV ARGO_DOMAIN="" \
    ARGO_AUTH="" \
    GITHUB_TOKEN="" \
    GITHUB_REPO_OWNER="" \
    GITHUB_REPO_NAME="" \
    GITHUB_BRANCH="" \
    ZIP_PASSWORD="" \
    NZ_CLIENT_SECRET="" \
    NZ_UUID="" \
    NZ_TLS="" \
    DASHBOARD_VERSION=""

# 复制脚本和静态文件
COPY backup.sh /backup.sh
COPY restore.sh /restore.sh
COPY entrypoint.sh /entrypoint.sh
COPY start_agent.py /start_agent.py
COPY start_cloudflared.py /start_cloudflared.py
COPY index.html /usr/share/nginx/html/index.html

# 设置可执行权限
RUN chmod +x /restore.sh /backup.sh /entrypoint.sh \
              /start_cloudflared.py /start_agent.py

# 启动脚本
CMD ["/entrypoint.sh"]
