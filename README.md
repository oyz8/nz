# V1 版哪吒面板 · 部署文档

容器化部署，自动备份到 GitHub，面板支持指定版本、可选自动更新、Argo 隧道。

> ⚠️ **首次安装完成后第一件事：进面板改密码**（默认 `admin/admin`）。  
> ⚠️ **Cloudflare 侧必须同时打开 `gRPC` 和 `WebSockets`**，否则 Agent 离线、终端/文件管理无法使用。  
> ⚠️ **Cloudflare Tunnel Token、GitHub Token、ZIP 密码均属敏感信息**，不要在日志、截图或公开渠道泄露。

---

## 目录

1. [部署前准备](#一部署前准备)
2. [环境变量](#二环境变量)
3. [部署容器](#三部署容器)
4. [启动流程](#四启动流程)
5. [备份与恢复](#五备份与恢复)
6. [路径分流架构](#六路径分流架构)
7. [项目结构](#七项目结构)
8. [常见问题](#八常见问题)
9. [关键说明](#九关键说明)

---

# 一、部署前准备

## 1.1 创建 GitHub 备份仓库

1. 新建一个 **Private** 仓库，例如 `nezha-backup`
2. 勾选 **Add a README file**
3. 记下：
   - `GITHUB_REPO_OWNER` = GitHub 用户名
   - `GITHUB_REPO_NAME` = 仓库名，如 `nezha-backup`

> 备份文件以 `data-*.zip` 形式存放在仓库根目录，通过 GitHub Contents API 管理。

## 1.2 生成 GitHub Token

任选一种方式。

### 方式 A：Classic Token（简单）

**Settings → Developer settings → Personal access tokens → Tokens (classic) → Generate new token (classic)**

- Expiration：**No expiration**
- 权限：✅ `repo`

Token 格式：`ghp_xxxxxxxxxxxx`

### 方式 B：Fine-grained Token（推荐，最小权限）

**Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**

- **Resource owner**：你的账号
- **Repository access**：Only select repositories → 选择备份仓库
- **Permissions**：
  - ✅ **Contents**: Read and write
  - ✅ **Metadata**: Read

Token 格式：`github_pat_xxxxxxxxxxxx`

> 两种 Token 都只显示一次，立刻复制保存。

## 1.3 创建 Cloudflare Tunnel

1. **Zero Trust → Networks → Tunnels → Create a tunnel → Cloudflared**
2. 复制 `eyJ` 开头的 Token → `ARGO_AUTH`
3. 记下面板域名 → `ARGO_DOMAIN`

Public Hostname 与路径分流配置见 [第六部分](#六路径分流架构)。

## 1.4 Cloudflare 网络开关

进入 Cloudflare 仪表盘 → 选择回退源域名（如 `nezha.nyc.mn`）→ 左侧 **网络**：

| 开关 | 作用 | 不开启的后果 |
|---|---|---|
| ✅ **gRPC** | Agent 通过 HTTP/2 gRPC 上报数据 | Agent 无法上报，面板显示离线 |
| ✅ **WebSockets** | 面板终端、文件管理、实时日志等长连接 | 终端连不上、文件管理打不开、实时数据不刷新 |

> 方案 B 下，只需给回退源域名开启这两个开关，自定义主机名不需要单独开。

---

# 二、环境变量

> 定义：
> - **首次安装** = GitHub 备份仓库里没有 `data-*.zip`
> - **有备份** = 仓库里至少有一个 `data-*.zip`

## 2.1 必需变量

| 变量 | 首次安装 | 有备份 | 说明 |
|---|:---:|:---:|---|
| `ARGO_AUTH` | ✅ | ✅ | Cloudflare Tunnel Token |
| `ARGO_DOMAIN` | ✅ | ✅ | Agent 连接地址 / SaaS 回退源 |
| `GITHUB_TOKEN` | ✅ | ✅ | 备份/恢复用 GitHub Token |
| `GITHUB_REPO_OWNER` | ✅ | ✅ | 备份仓库所有者 |
| `GITHUB_REPO_NAME` | ✅ | ✅ | 备份仓库名 |
| `ZIP_PASSWORD` | ✅ | ✅ | 备份加密密码 |

## 2.2 `NZ_UUID` 的条件必需

`NZ_UUID` 有两个用途：

1. 首次安装时生成 `config.yml`
2. 备份里没有 `config.yml` 时，重新生成 Agent 配置

| 场景 | 是否需要 `NZ_UUID` |
|---|---|
| 首次安装（GitHub 无备份） | ✅ 需要 |
| 有备份 + 备份含 `config.yml` | ❌ 不需要 |
| 有备份 + 备份不含 `config.yml` + 想监控容器自己 | ✅ 需要 |
| 有备份 + 备份不含 `config.yml` + 不监控容器自己 | ❌ 不需要 |

> **建议**：首次部署时无论如何都设上 `NZ_UUID`。这样首次备份就会包含 `config.yml`，未来迁移可直接恢复，不用再管这个变量。  
> 在线生成 UUID：<https://www.uuidgenerator.net/>

## 2.3 可选变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `NZ_TLS` | `true` | Agent TLS 开关 |
| `GITHUB_BRANCH` | `main` | 备份仓库分支 |
| `BACKUP_KEEP_COUNT` | `5` | 保留最近 N 个备份 |
| `TRANSFERS_KEEP_DAYS` | `7` | 备份中保留最近 N 天的流量记录 |
| `DASHBOARD_VERSION` | 空 | 留空 = latest；设值则锁定版本 如：v2.2.10 |

## 2.4 ZIP 包内部结构

```text
data-2026-09-18-02-30-00.zip
├── config.yml              ← agent 配置
└── data/
    ├── config.yaml         ← dashboard 配置
    └── sqlite.db           ← dashboard 数据库
```

> **口诀**：首次安装填 `NZ_UUID`；备份含 `config.yml` 时什么都别管，恢复即用；备份缺 `config.yml` 又想监控容器自己，也得填 `NZ_UUID`。

---

# 三、部署容器

把环境变量配置到 Koyeb / Docker / 其他平台，启动容器。

## 3.1 Docker Run 示例

```bash
docker run -d \
  --name argo-nezha \
  --restart unless-stopped \
  -v "$(pwd)/data:/app/data" \
  -e ARGO_DOMAIN=nezha.example.com \
  -e ARGO_AUTH=eyJ... \
  -e GITHUB_TOKEN=ghp_... \
  -e GITHUB_REPO_OWNER=yourname \
  -e GITHUB_REPO_NAME=nezha-backup \
  -e ZIP_PASSWORD=yourpassword \
  -e NZ_UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
  <镜像地址>
```

## 3.2 Docker Compose 示例

```yaml
services:
  argo-nezha:
    image: <镜像地址>
    container_name: argo-nezha
    restart: unless-stopped
    volumes:
      - ./data:/app/data
    environment:
      - ARGO_DOMAIN=nezha.example.com
      - ARGO_AUTH=eyJ...
      - GITHUB_TOKEN=ghp_...
      - GITHUB_REPO_OWNER=yourname
      - GITHUB_REPO_NAME=nezha-backup
      - ZIP_PASSWORD=yourpassword
      - NZ_UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

## 3.3 其他平台

按平台要求配置上述环境变量，并持久化 `/app/data`。  
若平台支持，也建议持久化 `/app/config.yml`；否则常规启动时会从 GitHub 备份恢复。

---

# 四、启动流程

## 4.0 设计原则

| 服务 | 生命周期 | 原因 |
|---|---|---|
| nginx | **全程在线**，只启动一次 | 保证 80 端口持续监听，健康检查不中断 |
| cloudflared | **全程在线**，只启动一次 | 隧道连接稳定，避免重连延迟 |
| dashboard | 启动 → 杀 → 恢复 → 重启 | 恢复数据前必须释放数据库 |
| agent | 数据恢复后再启动 | 使用恢复后的 `config.yml` |

## 4.1 分支判断

```text
main()
  │
  ├─ 1. 环境变量检查
  ├─ 2. 初始化 nginx / SSL
  ├─ 3. 下载 dashboard + agent
  ├─ 4. 启动 nginx + cloudflared（全程在线）
  │
  └─ 5. 检查 GitHub 是否有 data-*.zip
        ├─ 无 → 首次安装模式
        └─ 有 → 常规启动模式
```

## 4.2 首次安装（GitHub 无备份）

```text
├─ start_nginx_cloudflared
├─ start_dashboard
├─ sleep 3
├─ start_agent
│    ├─ config.yml 不存在
│    ├─ 从 data/config.yaml 读 agent_secret_key → client_secret
│    ├─ server = $ARGO_DOMAIN:443, uuid = $NZ_UUID
│    └─ 生成 config.yml，启动 agent
├─ 50秒后自动触发 backup.sh
└─ print_processes
```

关键点：

- 首次安装需要 `NZ_UUID`，这是唯一一次强制需要。
- 结束时50秒后自动触发首次备份，把 `data/` + `config.yml` 上传。
- 备份成功后，下次启动进入常规启动分支，一般不再需要 `NZ_UUID`。

## 4.3 常规启动（GitHub 有备份）

```text
├─ start_nginx_cloudflared
├─ start_dashboard
├─ sleep 3
├─ pkill dashboard
├─ restore.sh
│    ├─ 下载最新备份或指定备份
│    ├─ 解压到临时目录
│    ├─ 恢复 /app/data/*
│    ├─ 恢复 /app/config.yml（如备份中存在）
│    └─ 清理 WAL/SHM
├─ start_dashboard
├─ sleep 3
├─ start_agent
│    ├─ config.yml 已恢复   → 直接用
│    └─ config.yml 不存在   → 检查 NZ_UUID
│         ├─ 有 NZ_UUID    → 从 data/config.yaml 读 agent_secret_key 生成
│         └─ 无 NZ_UUID    → 警告，跳过 agent
└─ print_processes
```

> 常规启动一般不需要 `NZ_UUID`，但如果备份里没有 `config.yml`，就需要。

---

# 五、备份与恢复

## 5.1 备份结构

```text
data-2026-09-18-02-30-00.zip
├── config.yml              ← agent 配置（含 client_secret + uuid）
└── data/
    ├── config.yaml         ← 面板配置（含 agent_secret_key）
    └── sqlite.db           ← 面板数据库
```

ZIP 使用 `ZIP_PASSWORD` 加密，上传到 GitHub 仓库根目录，通过 Contents API 管理。

> `config.yml` 可能不存在：首次安装未设 `NZ_UUID`，或来自早期版本/其他项目备份。  
> 恢复脚本会兼容处理，缺失时若设了 `NZ_UUID` 会自动重新生成。

## 5.2 首次安装自动触发备份 ⚠️

首次安装完成后，脚本会自动执行一次 `backup.sh`，把当前初始状态上传到 GitHub 仓库。

这一步很关键：

| 首次安装时的动作 | 结果 |
|---|---|
| dashboard 初始化 `data/config.yaml`，含随机 `agent_secret_key` | ✅ 存入备份 |
| agent 用 `agent_secret_key` + `NZ_UUID` 生成 `config.yml` | ✅ 存入备份 |
| 整个初始状态打包上传 GitHub | ✅ 下次启动可直接恢复 |

为什么重要：

1. **建立「有备份」状态**：下次容器重启或换机，走常规启动，不再需要 `NZ_UUID`。
2. **保住 `agent_secret_key`**：这是随机值。若没备份，容器重建后面板会生成新值，导致所有已注册 Agent 失联。
3. **免填 `NZ_UUID`**：首次备份成功后，后续启动靠备份恢复即可。

如果首次备份失败：

- 容器仍运行，面板可用；
- 但下次重启会回到「首次安装」模式，生成新的 `agent_secret_key`；
- 所有已注册 Agent 会被视为新机器，需要重新添加；
- **强烈建议**：首次安装后去 GitHub 确认仓库里有 `data-*.zip`。

> 手动重试：把 GitHub 仓库的 `README.md` 内容改为 `backup`，等最多 1 小时脚本会自动重试。

## 5.3 手动触发备份

将 GitHub 备份仓库中的 `README.md` 内容**全部替换**为：

```text
backup
```

容器在下次检查（最多 1 小时）时会立即执行备份。

> ⚠️ 内容必须**只有** `backup` 6 个字符，不含空格、换行或其他字符。

## 5.4 指定恢复备份

将 GitHub 备份仓库中的 `README.md` 内容**全部替换**为要恢复的文件名：

```text
data-2026-08-18-14-30-00.zip
```

重新部署容器时会恢复指定备份；如果该文件不存在，自动回退到最新备份。

> ⚠️ 内容必须**只有文件名本身**。

## 5.5 备份触发逻辑

```text
每小时执行一次
    │
    ├─ 自动备份检查（需要 GitHub 相关变量已设置）
    │    ├─ 查 GitHub 最新备份文件
    │    ├─ 没有备份文件？                 → 触发备份
    │    ├─ 最新备份日期 ≠ 今天 且 小时 ≥ 4 → 触发备份
    │    └─ 其它                           → 跳过
    │
    └─ 版本更新检查
         ├─ DASHBOARD_VERSION 未设置 → 跑 renew.sh
         └─ DASHBOARD_VERSION 已设置 → 跳过（锁定版本）
```

> 首次安装时，`main()` 流程结束时直接调用一次 `backup.sh`，不等 while 循环，保证初始状态立即上传。

## 5.6 迁移 / 换机

从旧实例换到新实例，行为等同于**常规启动**：

1. GitHub 有备份 → 走常规启动分支；
2. 恢复 `data/` + `config.yml`；
3. Agent 用恢复的配置启动。

| 迁移场景 | 是否需要 `NZ_UUID` |
|---|---|
| 备份含 `config.yml` | ❌ 不需要 |
| 备份不含 `config.yml` + 想监控容器自己 | ✅ 需要 |
| 备份不含 `config.yml` + 不监控容器自己 | ❌ 不需要 |
| 备份来自其他项目、结构不一样 | 视情况，见 FAQ |

## 5.7 跨项目迁移兼容

不同项目/版本的备份结构可能不一致：

| 结构 | 示例 | 来源 |
|---|---|---|
| 标准（当前） | `data/config.yaml` + `data/sqlite.db` + `config.yml` | 本项目新版本 |
| 旧版（无 `data/`） | `config.yaml` + `sqlite.db` 直接在根 | 本项目早期版本 |
| 面板目录布局 | `dashboard/data/config.yaml` | 其他封装项目 |
| 全量打包 | `app/data/config.yaml` + `app/config.yml` | 自定义脚本 |

`restore.sh` 已兼容：

- 标准结构 `data/sqlite.db`
- 旧版结构根目录 `sqlite.db`
- 其他结构会自动跳过，**不破坏已有数据**

如果结构非常规，可手动解压查看后调整，或参考 `restore.sh` 里的 `find` 兜底逻辑适配。

---

# 六、路径分流架构

## 6.1 核心思路

- **Agent gRPC 通信**：`/proto.NezhaService/*` 继续走 Nginx（`localhost:80`），由 Nginx 提供稳定的 HTTP/2 和 gRPC 代理支持。
- **面板 HTTP/API 请求**：所有其他路径 `*` 直连 Dashboard（`localhost:8008`），不再经过 Nginx 反代，避免 Nginx 对长连接或 gRPC 协议处理不当导致的间歇性 502。

## 6.2 方案 A：共用同一个域名（推荐）

Cloudflare Tunnel 配**一个 Subdomain**，拆两条路径规则：

| 顺序 | Domain | Type | URL | 路径 | 用途 |
|---|---|---|---|---|---|
| 1 | `nezha.nyc.mn` | HTTP | `localhost:80` | `/proto.NezhaService/*` | Agent gRPC 经 Nginx |
| 2 | `nezha.nyc.mn` | HTTP | `localhost:8008` | `*` | 面板直连 Dashboard |

- `ARGO_DOMAIN` = `nezha.nyc.mn`
- 浏览器打开 `https://nezha.nyc.mn` 就是面板
- Agent 连接 `nezha.nyc.mn:443`

> **规则顺序很重要**：`/proto.NezhaService/*` 必须排在 `*` 之前，Cloudflare 按顺序匹配，命中即停止。

## 6.3 方案 B：SaaS 自定义主机名

Cloudflare Tunnel 作为**回退源**，所有面板域名通过 **Cloudflare for SaaS 自定义主机名**访问。

关键点：SaaS 回退时**保留原始 Host**，Tunnel 按 Host + Path 匹配，所以**每个自定义主机名都要在 Tunnel 里单独配一条 `*` 规则**。

### B.1 Tunnel Public Hostname 规则

| 顺序 | Domain | Type | URL | 路径 | 用途 |
|---|---|---|---|---|---|
| 1 | `nezha.nyc.mn` | HTTP | `localhost:80` | `/proto.NezhaService/*` | Agent gRPC 经 Nginx |
| 2 | `nezha.loc.cc` | HTTP | `localhost:8008` | `*` | 面板直连 Dashboard |
| 3 | `nezha.A.tw` | HTTP | `localhost:8008` | `*` | 面板直连 Dashboard |
| 4 | `nezha.B.kg` | HTTP | `localhost:8008` | `*` | 面板直连 Dashboard |
| 5 | `nezha.C.og` | HTTP | `localhost:8008` | `*` | 面板直连 Dashboard |
| … | 其他自定义主机名 | HTTP | `localhost:8008` | `*` | 每个 SaaS 域名一条 |

- `ARGO_DOMAIN` = `nezha.nyc.mn`（Agent 连接地址）
- Agent 连接 `nezha.nyc.mn:443`

### B.2 Cloudflare for SaaS

进入 **SSL/TLS → 自定义主机名**：

| 配置项 | 值 |
|---|---|
| 回退源 | `nezha.nyc.mn` |
| 自定义主机名 | `nezha.loc.cc`、`nezha.A.tw`、`nezha.B.kg`、`nezha.C.og` … |
| 每个自定义主机名 | 客户 CNAME 到 `nezha.nyc.mn` |

> ⚠️ 每在 SaaS 里添加一个自定义主机名，就要在 Tunnel 里同步添加一条对应的 `*` 规则，否则请求会走到 Tunnel 的 catch-all 规则返回 404。

### B.3 流量路径

```text
用户访问 https://nezha.loc.cc/
        │
        ▼
① Cloudflare 边缘节点
        │
        ▼
② Cloudflare for SaaS（自定义主机名匹配）
        │ 命中 nezha.loc.cc
        ▼
③ 回退到回退源：nezha.nyc.mn
        │ Host 头保留为 nezha.loc.cc
        ▼
④ Cloudflare Tunnel（回退源隧道入口）
        │ 按 Host + Path 匹配 ingress 规则
        ▼
⑤ 命中 nezha.loc.cc + * → localhost:8008（Dashboard）
```

### B.4 使用方式

| 访问方式 | 落到哪里 | 说明 |
|---|---|---|
| `https://nezha.nyc.mn/proto.NezhaService/*` | `localhost:80`（Nginx → gRPC） | Agent 上报 |
| `https://nezha.loc.cc/` | `localhost:8008`（Dashboard） | 客户域名 A |
| `https://nezha.A.tw/` | `localhost:8008`（Dashboard） | 客户域名 A |
| `https://nezha.B.kg/` | `localhost:8008`（Dashboard） | 客户域名 B |
| `https://nezha.C.og/` | `localhost:8008`（Dashboard） | 客户域名 C |

### B.5 维护口诀

> **加一个域名 = SaaS 加一条 + Tunnel 加一条。**

## 6.4 Cloudflare 侧必须开启 gRPC + WebSockets

进入 Cloudflare 仪表盘 → 选中回退源域名（如 `nezha.nyc.mn`）→ 左侧菜单 **网络**：

| 开关 | 作用 | 不开启的后果 |
|---|---|---|
| ✅ **gRPC** | Agent 通过 HTTP/2 gRPC 上报数据 | Agent 无法上报，面板显示探针离线 |
| ✅ **WebSockets** | 面板终端、文件管理、实时日志等长连接 | 终端连不上、文件管理打不开、实时数据不刷新 |

> 这两个开关与 Nginx 的 `grpc_pass` / `Upgrade` 配置是独立环节，缺一不可：
> - Nginx 负责容器内部的反代和协议转发；
> - Cloudflare 负责边缘网络对 HTTP/2 gRPC 和 WebSocket 升级的放行。
>
> 方案 B 下，只需给回退源域名开启这两个开关即可，自定义主机名不需要单独开。

---

# 七、项目结构

```text
.
├── Dockerfile
└── file/
    ├── start.sh       # 入口：下载、启动、恢复、定时循环
    ├── backup.sh      # 备份：打包上传 GitHub
    ├── restore.sh     # 恢复：下载解压覆盖
    ├── restart.sh     # 重启 dashboard
    └── renew.sh       # 检查更新 dashboard / agent
```

---

# 八、常见问题

| 问题 | 解决办法 |
|---|---|
| **首次安装后 GitHub 仓库没出现备份** | 检查 `GITHUB_TOKEN`、`GITHUB_REPO_OWNER`、`GITHUB_REPO_NAME`、`ZIP_PASSWORD` 是否正确，Token 是否有 `repo` 或 Contents 读写权限；也可手动把 README 改为 `backup` 重试 |
| **首次备份失败导致重启后 Agent 全部失联** | 说明 `agent_secret_key` 没被保存。重启后面板生成新 secret，需要重新添加 Agent；先手动触发备份再重启 |
| **备份里没有 `config.yml`，Agent 没启动** | 备份来自旧版本或其他项目。若想监控容器自己，设置 `NZ_UUID`，脚本会从恢复的 `data/config.yaml` 读 `agent_secret_key` 重新生成 `config.yml` |
| **跨项目迁移，备份结构不一样** | 支持标准结构 `data/sqlite.db` 和旧版结构根目录 `sqlite.db`；其他结构自动跳过且不破坏数据。可手动解压查看后适配 |
| 面板打开但探针离线 | Cloudflare 未开启 gRPC：选择域名 → 网络 → 打开 gRPC 开关 |
| 面板打开但终端/文件管理连不上 | Cloudflare 未开启 WebSockets：同上位置打开 WebSockets 开关 |
| 面板打开但 Agent 离线 | 检查 `config.yml` 里的 `client_secret` 是否与 `data/config.yaml` 的 `agent_secret_key` 一致 |
| 恢复后 Agent 没启动 | 检查备份里是否有 `config.yml`；若没有，需设置 `NZ_UUID` 让脚本重新生成 |
| 备份文件太大 | 减小 `TRANSFERS_KEEP_DAYS` 或 `BACKUP_KEEP_COUNT` |
| 手动备份没触发 | README 内容必须只有 `backup` |
| 指定恢复没生效 | README 内容必须只有 `data-xxx.zip`，且该文件确实存在 |
| 面板版本没更新 | `DASHBOARD_VERSION` 已设置会锁定版本，改为留空即可跟随最新 |
| 面板间歇性 502 | 检查 Cloudflare Tunnel 路由是否按第六部分分流：面板直连 8008，Agent 走 Nginx 80 |
| 方案 A 下 Agent 连不上 | 确认 `/proto.NezhaService/*` 规则排在 `*` 规则之前 |
| 方案 B 下 `nezha.nyc.mn/` 访问 404 | 正常现象，`nezha.nyc.mn` 只用于 gRPC，面板请用 `nezha.loc.cc` |
| SaaS 客户域名回退 404 | 检查是否在 Tunnel 里为对应域名加了 `*` → `localhost:8008` 规则 |

---

# 九、关键说明

| 项 | 说明 |
|---|---|
| `NZ_UUID` | 两个用途：① 首次安装生成 `config.yml`；② 备份里没有 `config.yml` 时重新生成 Agent 配置。有备份且备份含 `config.yml` 时不需要 |
| **首次安装自动备份** | 首次安装结束时立即触发 `backup.sh`，建立「有备份」状态，之后所有启动都是常规模式 |
| 备份包中的 `config.yml` | Agent 配置的权威来源，恢复后覆盖容器内的；若备份不含，且设了 `NZ_UUID`，会重新生成 |
| 备份保留天数 | 只影响 `transfers` 表（流量记录），其他表完整保留 |
| 存储方式 | GitHub 仓库根目录的 `data-*.zip` 文件，通过 Contents API 上传 |
| nginx 生命周期 | 全程在线，只在启动时启一次，不随恢复流程重启 |
| cloudflared 生命周期 | 全程在线，只在启动时启一次 |
| dashboard 生命周期 | 首次启动 → 常规启动时杀一次 → 恢复后重启 |
| **Cloudflare 网络开关** | **gRPC + WebSockets 都要打开**，缺一不可 |

## 相关文件

| 文件 | 用途 |
|---|---|
| `/app/data/config.yaml` | 面板配置，含 `agent_secret_key` |
| `/app/data/sqlite.db` | 面板数据库 |
| `/app/config.yml` | Agent 配置，含 `client_secret` + `uuid` |
| `/app/data.bak.*` | 恢复前的旧数据，自动保留最近 1 份 |

---

**安全提示**：Cloudflare Tunnel Token、GitHub Token、ZIP 密码属于敏感信息，不要在日志、截图或公开渠道泄露。首次安装完成后立即修改面板默认密码。
