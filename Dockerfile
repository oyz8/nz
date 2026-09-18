FROM nginx:latest

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        wget \
        unzip \
        bash \
        curl \
        openssl \
        jq \
        procps \
        tzdata \
        zip \
        sqlite3 \
    && rm -rf /var/lib/apt/lists/*

COPY file/* /app/

WORKDIR /app

RUN chmod +x start.sh backup.sh restore.sh restart.sh renew.sh

EXPOSE 443 8008

ENTRYPOINT ["/app/start.sh"]
