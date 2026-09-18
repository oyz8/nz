#!/bin/bash
# Nezha 数据备份脚本
set -u
set -o pipefail

# ========== 统一日志 ==========
ts()   { TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S'; }
info() { echo "[$(ts)] [INFO] $*"; }
ok()   { echo "[$(ts)] [ OK ] $*"; }
warn() { echo "[$(ts)] [WARN] $*"; }
fail() { echo "[$(ts)] [FAIL] $*"; }
sub()  { echo "[$(ts)] [INFO]     └─ $*"; }
step() { echo; echo "[$(ts)] [STEP] ===== $* ====="; }

# ---------- 1. 依赖检查 ----------
for cmd in sqlite3 zip base64 curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        fail "缺少命令: $cmd"
        exit 1
    fi
done

# ---------- 2. 环境变量检查 ----------
if [ -z "${GITHUB_TOKEN:-}" ] || [ -z "${GITHUB_REPO_OWNER:-}" ] || [ -z "${GITHUB_REPO_NAME:-}" ] || [ -z "${ZIP_PASSWORD:-}" ]; then
    warn "缺少备份环境变量，跳过备份"
    sub "需要: GITHUB_TOKEN, GITHUB_REPO_OWNER, GITHUB_REPO_NAME, ZIP_PASSWORD"
    exit 0
fi

# ---------- 3. 变量定义 ----------
BACKUP_KEEP_COUNT="${BACKUP_KEEP_COUNT:-5}"
TRANSFERS_KEEP_DAYS="${TRANSFERS_KEEP_DAYS:-7}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
API_BASE="https://api.github.com/repos/$GITHUB_REPO_OWNER/$GITHUB_REPO_NAME"
WORK_DIR=/app
TEMP_DIR="/tmp/nezha-backup-$$"
TIMESTAMP=$(TZ='Asia/Shanghai' date +"%Y-%m-%d-%H-%M-%S")
BACKUP_FILE="data-${TIMESTAMP}.zip"
CURL_OPTS="-s --retry 3 --retry-delay 3 --retry-connrefused"
DB_ERR="$TEMP_DIR/db-err.log"

trap 'rm -rf "$TEMP_DIR"' EXIT

# ---------- 4. 数据目录检查 ----------
if [ ! -d "$WORK_DIR/data" ]; then
    warn "数据目录不存在: $WORK_DIR/data，跳过备份"
    exit 0
fi

mkdir -p "$TEMP_DIR/data"

DB_FILE="$WORK_DIR/data/sqlite.db"
DB_BACKUP="$TEMP_DIR/data/sqlite.db"

# ---------- 5. 开始备份 ----------
step "Nezha 数据备份"
info "仓库: $GITHUB_REPO_OWNER/$GITHUB_REPO_NAME"
info "分支: $GITHUB_BRANCH"
info "文件名: $BACKUP_FILE"
sub "保留备份数量: $BACKUP_KEEP_COUNT"
sub "transfers 保留天数: $TRANSFERS_KEEP_DAYS"

# ---------- 6. 在线备份数据库 ----------
if [ -f "$DB_FILE" ]; then
    info "备份数据库（在线方式）..."

    sqlite3 "$DB_FILE" "PRAGMA wal_checkpoint(PASSIVE);" >/dev/null 2>&1 || true

    DB_OK=0

    if sqlite3 "$DB_FILE" ".timeout 60000" "VACUUM INTO '$DB_BACKUP'" 2>"$DB_ERR"; then
        ok "数据库在线备份成功（VACUUM INTO）"
        DB_OK=1
    else
        sub "VACUUM INTO 失败: $(cat "$DB_ERR" 2>/dev/null | tr -d '\n')"
        if sqlite3 "$DB_FILE" ".timeout 60000" ".backup '$DB_BACKUP'" 2>"$DB_ERR"; then
            ok "数据库备份成功（.backup）"
            DB_OK=1
        else
            sub ".backup 失败: $(cat "$DB_ERR" 2>/dev/null | tr -d '\n')"
        fi
    fi

    if [ "$DB_OK" -eq 0 ]; then
        fail "数据库备份失败，终止本次备份"
        exit 1
    fi

    sub "数据库副本大小: $(du -h "$DB_BACKUP" | cut -f1)"
else
    warn "未找到 sqlite.db，跳过数据库备份"
fi

# ---------- 7. 复制 data 目录其它文件 ----------
info "复制其他数据文件..."
for item in "$WORK_DIR/data"/*; do
    [ -e "$item" ] || continue
    base=$(basename "$item")
    case "$base" in
        sqlite.db|sqlite.db-wal|sqlite.db-shm)
            ;;
        *)
            cp -R "$item" "$TEMP_DIR/data/" 2>/dev/null || true
            ;;
    esac
done

# ---------- 7.1 复制 /app/config.yml（agent 配置） ----------
if [ -f "$WORK_DIR/config.yml" ]; then
    cp "$WORK_DIR/config.yml" "$TEMP_DIR/config.yml" 2>/dev/null || true
    sub "已包含 config.yml（agent 配置）"
else
    sub "无 config.yml，跳过"
fi
ok "其他数据文件复制完成"

# ---------- 8. 清理副本中的历史数据 ----------
if [ -f "$DB_BACKUP" ]; then
    info "清理 ${TRANSFERS_KEEP_DAYS} 天前的 transfers 记录..."
    sqlite3 "$DB_BACKUP" ".timeout 60000" \
        "DELETE FROM transfers WHERE created_at < date('now','-${TRANSFERS_KEEP_DAYS} days');" \
        >/dev/null 2>&1 || true

    info "压缩数据库（VACUUM）..."
    sqlite3 "$DB_BACKUP" ".timeout 60000" "VACUUM;" >/dev/null 2>&1 || true

    sub "清理后数据库副本大小: $(du -h "$DB_BACKUP" | cut -f1)"
fi

rm -rf "$TEMP_DIR/data/upload" 2>/dev/null || true
rm -f "$TEMP_DIR/data/"*.log 2>/dev/null || true

# ---------- 9. 打包加密 ----------
info "ZIP 压缩数据（加密）..."
cd "$TEMP_DIR" || { fail "无法进入临时目录"; exit 1; }

# 收集要打包的项：data/ 一定有，config.yml 可能没有
ZIP_TARGETS="data/"
[ -f "$TEMP_DIR/config.yml" ] && ZIP_TARGETS="$ZIP_TARGETS config.yml"

zip -r -6 -P "$ZIP_PASSWORD" "$BACKUP_FILE" $ZIP_TARGETS >/dev/null 2>&1

if [ ! -f "$BACKUP_FILE" ]; then
    fail "压缩失败"
    exit 1
fi

BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
sub "备份文件大小: $BACKUP_SIZE"

# ---------- 10. Base64 ----------
base64 -w 0 "$BACKUP_FILE" > content.b64 2>/dev/null || base64 "$BACKUP_FILE" > content.b64

B64_SIZE=$(wc -c < content.b64 | tr -d ' ')
case "$B64_SIZE" in
    ''|*[!0-9]*)
        fail "无法读取 base64 大小"
        exit 1
        ;;
esac

if [ "$B64_SIZE" -gt 47000000 ]; then
    warn "文件太大（base64 后 >47MB），无法通过 GitHub Contents API 上传"
    sub "建议改用 git push 或 GitHub Releases"
    exit 0
fi

# ---------- 11. 分支检查 ----------
HTTP_CODE=$(curl $CURL_OPTS -o /dev/null -w "%{http_code}" \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
    "$API_BASE/branches/$GITHUB_BRANCH")

if [ "$HTTP_CODE" != "200" ]; then
    warn "分支不存在或 Token 无权限: $GITHUB_BRANCH (HTTP $HTTP_CODE)"
    exit 0
fi
ok "分支检查通过"

# ---------- 12. 上传备份 ----------
info "上传备份文件到 GitHub..."

jq -n --rawfile content content.b64 \
    --arg msg "备份: $BACKUP_FILE ($BACKUP_SIZE)" \
    --arg branch "$GITHUB_BRANCH" \
    '{message: $msg, content: $content, branch: $branch}' > payload.json

RESPONSE=$(curl $CURL_OPTS -X PUT \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary @payload.json \
    "$API_BASE/contents/$BACKUP_FILE")

if echo "$RESPONSE" | jq -e '.content.sha' >/dev/null 2>&1; then
    ok "备份文件已上传 ✓"
else
    fail "上传失败: $(echo "$RESPONSE" | jq -r '.message // "未知错误"')"
    exit 1
fi

# ---------- 13. 更新 README.md ----------
info "更新 README.md..."

README_TEXT="# Nezha 数据备份

## 最新备份信息
- **文件名**: \`$BACKUP_FILE\`
- **备份时间**: $(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')
- **文件大小**: $BACKUP_SIZE
- **transfers 保留**: 最近 $TRANSFERS_KEEP_DAYS 天

## 恢复说明
设置环境变量后容器会自动恢复最新备份。

## 手动触发备份
将本文件内容修改为 \`backup\` 即可触发手动备份。

## 指定恢复备份
将本文件内容修改为 \`data-2026-09-18-04-00-00.zip\` 即可指定恢复该备份。

## 环境变量
- \`GITHUB_REPO_OWNER\`: GitHub 用户名
- \`GITHUB_REPO_NAME\`: GitHub 仓库名称
- \`GITHUB_TOKEN\`: GitHub Token
- \`GITHUB_BRANCH\`: GitHub 备份分支
- \`ZIP_PASSWORD\`: 备份密码
- \`TRANSFERS_KEEP_DAYS\`: 备份中保留的 transfers 天数（默认 7）
"

README_B64=$(echo -n "$README_TEXT" | base64 -w 0 2>/dev/null || echo -n "$README_TEXT" | base64)

README_SHA=$(curl $CURL_OPTS -H "Authorization: token $GITHUB_TOKEN" \
    "$API_BASE/contents/README.md?ref=$GITHUB_BRANCH" | jq -r '.sha // empty')

if [ -n "$README_SHA" ]; then
    jq -n --arg msg "更新README: $BACKUP_FILE" \
        --arg content "$README_B64" \
        --arg sha "$README_SHA" \
        --arg branch "$GITHUB_BRANCH" \
        '{message: $msg, content: $content, sha: $sha, branch: $branch}' > readme.json
else
    jq -n --arg msg "创建README" \
        --arg content "$README_B64" \
        --arg branch "$GITHUB_BRANCH" \
        '{message: $msg, content: $content, branch: $branch}' > readme.json
fi

curl $CURL_OPTS -X PUT \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary @readme.json \
    "$API_BASE/contents/README.md" >/dev/null

ok "README.md 已更新 ✓"

# ---------- 14. 清理旧备份 ----------
info "清理旧备份..."
OLD_BACKUPS=$(curl $CURL_OPTS -H "Authorization: token $GITHUB_TOKEN" \
    "$API_BASE/contents?ref=$GITHUB_BRANCH" \
    | jq -r '.[].name' | grep '^data-.*\.zip$' | sort -r | tail -n +$((BACKUP_KEEP_COUNT + 1)))

if [ -n "$OLD_BACKUPS" ]; then
    for old_file in $OLD_BACKUPS; do
        OLD_SHA=$(curl $CURL_OPTS -H "Authorization: token $GITHUB_TOKEN" \
            "$API_BASE/contents/$old_file?ref=$GITHUB_BRANCH" | jq -r '.sha // empty')

        if [ -z "$OLD_SHA" ] || [ "$OLD_SHA" = "null" ]; then
            sub "获取 SHA 失败，跳过: $old_file"
            continue
        fi

        curl $CURL_OPTS -X DELETE \
            -H "Authorization: token $GITHUB_TOKEN" \
            -H "Content-Type: application/json" \
            --data-binary "{\"message\":\"删除旧备份: $old_file\",\"sha\":\"$OLD_SHA\",\"branch\":\"$GITHUB_BRANCH\"}" \
            "$API_BASE/contents/$old_file" >/dev/null
        sub "删除: $old_file"
    done
    ok "旧备份清理完成 ✓"
else
    sub "没有需要清理的旧备份"
fi

echo
ok "备份完成: $BACKUP_FILE 🎉"
