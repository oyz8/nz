#!/bin/bash
# Nezha 数据恢复脚本
set -u
set -o pipefail

# ========== 统一日志 ==========
ts()   { TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S'; }
info() { echo "[$(ts)] [INFO]     $*"; }
ok()   { echo "[$(ts)] [ OK ]     $*"; }
warn() { echo "[$(ts)] [WARN]     $*"; }
fail() { echo "[$(ts)] [FAIL]     $*"; }
sub()  { echo "[$(ts)] [INFO]         └─ $*"; }

# ---------- 1. 环境变量 ----------
if [ -z "${GITHUB_TOKEN:-}" ] || [ -z "${GITHUB_REPO_OWNER:-}" ] || [ -z "${GITHUB_REPO_NAME:-}" ] || [ -z "${ZIP_PASSWORD:-}" ]; then
    info "未配置备份恢复变量，跳过恢复"
    exit 0
fi

GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
API_BASE="https://api.github.com/repos/$GITHUB_REPO_OWNER/$GITHUB_REPO_NAME"
WORK_DIR=/app
TEMP_DIR="/tmp/nezha-restore-$$"
TMP_FILE="$TEMP_DIR/backup.zip"
CURL_OPTS="-s --retry 3 --retry-delay 3 --retry-connrefused"

mkdir -p "$TEMP_DIR"
trap "rm -rf $TEMP_DIR" EXIT

info "仓库: $GITHUB_REPO_OWNER/$GITHUB_REPO_NAME"
info "分支: $GITHUB_BRANCH"

# ---------- 2. 分支检查 ----------
HTTP_CODE=$(curl $CURL_OPTS -o /dev/null -w "%{http_code}" \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
    "$API_BASE/branches/$GITHUB_BRANCH")

if [ "$HTTP_CODE" != "200" ]; then
    warn "分支不存在: $GITHUB_BRANCH (HTTP $HTTP_CODE)，跳过"
    exit 0
fi
ok "分支检查通过"

# ---------- 3. 拉取文件列表 ----------
FILE_LIST=$(curl $CURL_OPTS -H "Authorization: token $GITHUB_TOKEN" \
    "$API_BASE/contents?ref=$GITHUB_BRANCH" | jq -r '.[].name')

if [ -z "$FILE_LIST" ]; then
    warn "无法获取仓库文件列表，跳过恢复"
    exit 0
fi
sub "仓库文件数: $(echo "$FILE_LIST" | wc -l)"

# ---------- 4. 读取 README ----------
README_CONTENT=$(curl $CURL_OPTS -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github.v3.raw" \
    "$API_BASE/contents/README.md?ref=$GITHUB_BRANCH" 2>/dev/null)

README_TRIMMED=$(echo "$README_CONTENT" | tr -d '[:space:]')

# ---------- 5. 决定恢复哪个文件 ----------
BACKUP_FILE=""

# 5.1 手动触发标记
if [ "$README_TRIMMED" = "backup" ]; then
    info "README 内容为手动触发标记，跳过恢复"
    exit 0
fi
sub "手动触发标记: 否"

# 5.2 README 整份就是一个文件名 → 指定恢复
if echo "$README_TRIMMED" | grep -qE '^data-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}\.zip$'; then
    info "README 指定恢复: $README_TRIMMED"
    if echo "$FILE_LIST" | grep -qxF "$README_TRIMMED"; then
        BACKUP_FILE="$README_TRIMMED"
        ok "指定文件存在，使用它"
    else
        warn "指定文件不存在: $README_TRIMMED，回退最新备份"
    fi
fi

# 5.3 没指定 / 指定无效 → 回退最新
if [ -z "$BACKUP_FILE" ]; then
    BACKUP_FILE=$(echo "$FILE_LIST" | grep '^data-.*\.zip$' | sort -r | head -n1)
    if [ -z "$BACKUP_FILE" ]; then
        warn "未找到任何备份文件，跳过恢复"
        exit 0
    fi
    sub "使用最新备份: $BACKUP_FILE"
fi

# ---------- 6. 下载 ----------
info "下载备份..."
HTTP_CODE=$(curl -L $CURL_OPTS -w "%{http_code}" \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github.v3.raw" \
    -o "$TMP_FILE" \
    "$API_BASE/contents/$BACKUP_FILE?ref=$GITHUB_BRANCH")

if [ "$HTTP_CODE" != "200" ] || [ ! -s "$TMP_FILE" ]; then
    warn "下载失败 (HTTP $HTTP_CODE)，跳过恢复"
    exit 0
fi
sub "文件大小: $(du -h "$TMP_FILE" | cut -f1)"

# ---------- 7. 验证 zip ----------
if ! unzip -t -P "$ZIP_PASSWORD" "$TMP_FILE" >/dev/null 2>&1; then
    warn "备份文件损坏或密码错误，跳过恢复"
    exit 0
fi
ok "zip 验证通过"

# ---------- 8. 解压到临时目录 ----------
info "解压恢复..."
mkdir -p "$TEMP_DIR/extract"

if ! unzip -P "$ZIP_PASSWORD" -o "$TMP_FILE" -d "$TEMP_DIR/extract" >/dev/null 2>&1; then
    warn "解压失败，跳过恢复"
    exit 0
fi
ok "解压完成"

# 数据库目录（兼容新旧两种格式）
if [ -d "$TEMP_DIR/extract/data" ] && [ -f "$TEMP_DIR/extract/data/sqlite.db" ]; then
    sub "格式: 新版（data/ 子目录）"
    EXTRACT_DATA="$TEMP_DIR/extract/data"
elif [ -f "$TEMP_DIR/extract/sqlite.db" ]; then
    sub "格式: 旧版（文件直接在根）"
    EXTRACT_DATA="$TEMP_DIR/extract"
else
    warn "解压后未找到 sqlite.db，跳过恢复"
    ls -la "$TEMP_DIR/extract" | sed 's/^/         /'
    exit 0
fi

# ---------- 9. 备份现有数据（mv，只留最近 1 份） ----------
if [ -d "$WORK_DIR/data" ] && [ -f "$WORK_DIR/data/sqlite.db" ]; then
    BACKUP_EXISTING="${WORK_DIR}/data.bak.$(date +%s)"
    info "移动现有数据到: $BACKUP_EXISTING"
    if ! mv "$WORK_DIR/data" "$BACKUP_EXISTING"; then
        warn "移动失败，跳过恢复"
        exit 0
    fi
    ls -dt "$WORK_DIR"/data.bak.* 2>/dev/null | tail -n +2 | xargs -r rm -rf
    ok "现有数据已归档"
fi

# ---------- 10. 恢复数据到 /app/data ----------
mkdir -p "$WORK_DIR/data"
if ! mv "$EXTRACT_DATA"/* "$WORK_DIR/data/" 2>/dev/null; then
    warn "移动数据文件失败"
    exit 0
fi
ok "数据已恢复"

# ---------- 11. 恢复 config.yml（agent 配置） ----------
if [ -f "$TEMP_DIR/extract/config.yml" ]; then
    cp "$TEMP_DIR/extract/config.yml" "$WORK_DIR/config.yml"
    sub "已恢复 config.yml（agent 配置）"
else
    sub "备份中无 config.yml，跳过（首次安装会生成）"
fi

# ---------- 12. 清理 WAL/SHM ----------
if [ -f "$WORK_DIR/data/sqlite.db" ]; then
    rm -f "$WORK_DIR/data/sqlite.db-wal" "$WORK_DIR/data/sqlite.db-shm" 2>/dev/null || true
    sqlite3 "$WORK_DIR/data/sqlite.db" ".timeout 60000" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
    sub "WAL/SHM 清理完成"
fi

# ---------- 13. 恢复后文件清单 ----------
info "恢复后文件:"
info "  /app/data/:"
ls -la "$WORK_DIR/data" | tail -n +2 | sed 's/^/         /'
if [ -f "$WORK_DIR/config.yml" ]; then
    info "  /app/config.yml:"
    ls -la "$WORK_DIR/config.yml" | sed 's/^/         /'
fi

ok "恢复完成 🎉"
