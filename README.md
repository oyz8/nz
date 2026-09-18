# V1 版哪吒面板 · 部署文档

容器化部署，自动备份到 GitHub，支持指定版本、可选自动更新、Argo 隧道。

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
3. 配置 Public Hostname（规则见 [第六部分](#六路径分流架构)）
4. 记下面板域名 → `ARGO_DOMAIN`

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
| `ARGO_DOMAIN` | ✅ | ✅ | Agent 连接地址（必须是 Tunnel 里已绑定规则的域名） |
| `GITHUB_TOKEN` | ✅ | ✅ | 备份/恢复用 GitHub Token |
| `GITHUB_REPO_OWNER` | ✅ | ✅ | 备份仓库所有者 |
| `GITHUB_REPO_NAME` | ✅ | ✅ | 备份仓库名 |
| `ZIP_PASSWORD` | ✅ | ✅ | 备份加密密码 |

## 2.2 `NZ_UUID` 的条件必需

`NZ_UUID` 有两个用途：

1. 首次安装时生成 `config.yml`（Agent 配置）
2. 备份里没有 `config.yml` 时，重新生成 Agent 配置

| 场景 | 是否需要 `NZ_UUID` |
|---|---|
| 首次安装（GitHub 无备份） | ✅ 需要 |
| 有备份 + 备份含 `config.yml` | ❌ 不需要 |
| 有备份 + 备份不含 `config.yml` + 想监控容器自己 | ✅ 需要 |
| 有备份 + 备份不含 `config.yml` + 不监控容器自己 | ❌ 不需要 |

> **建议**：首次部署时无论如何都设上 `NZ_UUID`。这样首次备份就会包含 `config.yml`，未来迁移可直接恢复，不用再管这个变量。
> 在线生成 UUID：<https://www.uuidgenerator.net/>

> ⚠️ **注意**：`NZ_UUID` 未设置或 `ARGO_DOMAIN` 未设置时，`start.sh` 会跳过 agent 的下载与启动。两个变量都设置，agent 才会被下载和运行。

## 2.3 可选变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `NZ_TLS` | `true` | Agent TLS 开关 |
| `GITHUB_BRANCH` | `main` | 备份仓库分支 |
| `BACKUP_KEEP_COUNT` | `5` | 保留最近 N 个备份 |
| `TRANSFERS_KEEP_DAYS` | `7` | 备份中保留最近 N 天的流量记录 |
| `DASHBOARD_VERSION` | 空 | 留空 = latest；设值则锁定版本，如 `v2.2.10` |

## 2.4 ZIP 包内部结构

```text
data-2026-09-18-02-30-00.zip
├── config.yml              ← agent 配置（含 client_secret + uuid）
└── data/
    ├── config.yaml         ← dashboard 配置（含 client_secret）
    └── sqlite.db           ← dashboard 数据库
```

> **口诀**：首次安装填 `NZ_UUID`；备份含 `config.yml` 时什么都别管，恢复即用；备份缺 `config.yml` 又想监控容器自己，也得填 `NZ_UUID`。

---

# 三、部署容器

目前测试可部署容器 Koyeb / Northflank / 其他平台容器自行测试。

**端口说明**：

| 端口 | 用途 | 对外暴露 |
|---|---|---|
| **443** | Nginx（HTTPS/TLS），Cloudflare Tunnel 入口 | ✅（通过 Tunnel） |
| **8008** | Dashboard 直连，容器健康检查 | ✅（仅容器内 + 健康检查） |

**健康检查配置**（Koyeb 等平台）：

| 项 | 值 |
|---|---|
| Protocol | HTTP |
| Port | **8008** |
| Path | `/` |

---

# 四、启动流程

## 4.0 设计原则

| 服务 | 生命周期 | 监听端口 | 原因 |
|---|---|---|---|
| nginx | **全程在线**，只启动一次 | 443 | 保证 Tunnel 入口持续可用，健康检查不中断 |
| cloudflared | **全程在线**，只启动一次 | — | 隧道连接稳定，避免重连延迟 |
| dashboard | 启动 → 杀 → 恢复 → 重启 | 8008 | 恢复数据前必须释放数据库 |
| agent | 数据恢复后再启动 | — | 使用恢复后的 `config.yml` |

## 4.1 分支判断

```text
main()
  │
  ├─ 0. 临时目录初始化
  ├─ 1. 环境变量检查
  ├─ 2. 初始化 nginx / SSL（生成自签名证书 + 写入配置）
  ├─ 3. 下载 dashboard（+ 满足条件时下载 agent）
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
├─ sleep 3（等待 dashboard 初始化 data 目录）
├─ start_agent
│    ├─ config.yml 不存在
│    ├─ 检查 NZ_UUID / ARGO_DOMAIN → 任一缺失则跳过 agent
│    ├─ 从 data/config.yaml 读 agent_secret_key → client_secret
│    ├─ server = $ARGO_DOMAIN:443, uuid = $NZ_UUID, tls = $NZ_TLS
│    └─ 生成 config.yml，启动 agent
├─ 打印警告提示（修改默认密码 admin/admin）
├─ sleep 50（给用户时间改密码）
├─ 触发 backup.sh（首次备份）
└─ print_processes
```

关键点：

- 首次安装需要 `NZ_UUID`，这是唯一一次强制需要。
- 等待 50 秒后自动触发首次备份，把 `data/` + `config.yml` 上传。
- 备份成功后，下次启动进入常规启动分支，一般不再需要 `NZ_UUID`。

## 4.3 常规启动（GitHub 有备份）

```text
├─ start_nginx_cloudflared
├─ start_dashboard
├─ sleep 3（等待 dashboard 初始化）
├─ pkill dashboard（释放数据库）
├─ sleep 1
├─ restore.sh
│    ├─ 下载最新备份或指定备份
│    ├─ 解压到临时目录
│    ├─ mv 现有 /app/data → /app/data.bak.<timestamp>（只保留最近 1 份）
│    ├─ mv 解压数据 → /app/data/
│    ├─ 恢复 /app/config.yml（如备份中存在）
│    └─ 清理 WAL/SHM
├─ start_dashboard
├─ sleep 3
├─ start_agent
│    ├─ config.yml 已恢复   → 直接用
│    └─ config.yml 不存在   → 检查 NZ_UUID / ARGO_DOMAIN
│         ├─ 有             → 从 data/config.yaml 读 agent_secret_key 生成
│         └─ 无             → 警告，跳过 agent
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
    ├── config.yaml         ← 面板配置（含 client_secret）
    └── sqlite.db           ← 面板数据库
```

ZIP 使用 `ZIP_PASSWORD` 加密，上传到 GitHub 仓库根目录，通过 Contents API 管理。

> `config.yml` 可能不存在：首次安装未设 `NZ_UUID`，或来自早期版本/其他项目备份。
> 恢复脚本会兼容处理，缺失时若设了 `NZ_UUID` 会自动重新生成。

## 5.2 备份内容说明

备份脚本（`backup.sh`）执行时：

1. 对 `sqlite.db` 优先使用 `VACUUM INTO` 在线热备，失败则回退到 `.backup` 命令
2. 复制 `data/` 目录中除 `sqlite.db-wal`、`sqlite.db-shm` 之外的所有文件
3. 若 `/app/config.yml` 存在，一并打包进 ZIP
4. 删除副本中 `TRANSFERS_KEEP_DAYS` 天前的 `transfers` 记录，并对副本执行 `VACUUM`
5. 清理 `data/upload/` 目录和 `*.log` 文件，减小备份体积
6. ZIP 文件通过 base64 编码后经 GitHub Contents API 上传；若 base64 后超过 47 MB，跳过上传并提示

## 5.3 首次安装自动触发备份 ⚠️

首次安装完成后，脚本会等待 **50 秒**（给用户改密码的时间），然后自动执行一次 `backup.sh`，把当前初始状态上传到 GitHub 仓库。

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

## 5.4 手动触发备份

将 GitHub 备份仓库中的 `README.md` 内容**全部替换**为：

```text
backup
```

容器在下次检查（最多 1 小时）时会立即执行备份。

> ⚠️ 内容必须**只有** `backup` 6 个字符，不含空格、换行或其他字符。
> ⚠️ 恢复脚本（`restore.sh`）在启动时检测到 `README.md` 内容为 `backup` 时，会直接跳过恢复流程，不会执行恢复操作。

## 5.5 指定恢复备份

将 GitHub 备份仓库中的 `README.md` 内容**全部替换**为要恢复的文件名：

```text
data-2026-08-18-14-30-00.zip
```

重新部署容器时会恢复指定备份；如果该文件不存在，自动回退到最新备份。

> ⚠️ 内容必须**只有文件名本身**，格式须为 `data-YYYY-MM-DD-HH-mm-ss.zip`。

## 5.6 备份触发逻辑

```text
每小时执行一次
    │
    ├─ 自动备份检查（需要 GITHUB_TOKEN / REPO_OWNER / REPO_NAME / ZIP_PASSWORD 均已设置）
    │    ├─ 查 GitHub 最新备份文件
    │    ├─ 没有备份文件？                 → 触发备份
    │    ├─ 最新备份日期 ≠ 今天 且 小时 ≥ 4 → 触发备份
    │    └─ 其他                           → 跳过（打印原因）
    │
    └─ 版本更新检查
         ├─ DASHBOARD_VERSION 未设置 → 跑 renew.sh
         └─ DASHBOARD_VERSION 已设置 → 跳过（锁定版本，打印提示）
```

> 首次安装时，`main()` 流程结束时直接调用一次 `backup.sh`，不等 while 循环，保证初始状态立即上传。

## 5.7 迁移 / 换机

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

## 5.8 跨项目迁移兼容

不同项目/版本的备份结构可能不一致，`restore.sh` 的兼容策略：

| 结构 | 示例 | 来源 | 是否支持 |
|---|---|---|---|
| 标准（当前） | `data/config.yaml` + `data/sqlite.db` + `config.yml` | 本项目 | ✅ 完整支持 |
| 旧版（无 `data/`） | `config.yaml` + `sqlite.db` 直接在根 | 本项目早期版本 | ✅ 兼容支持 |
| 其他结构 | `dashboard/data/config.yaml` 等 | 其他封装项目 | ⚠️ 自动跳过，不破坏已有数据 |

恢复脚本优先查找 `data/sqlite.db`（新版格式），其次查找根目录 `sqlite.db`（旧版格式），均未找到则跳过恢复并列出解压内容供参考。

---

# 六、路径分流架构

## 6.1 核心思路

Nginx 仅监听 **443 端口**（HTTPS/TLS，使用自签名证书）。Cloudflare Tunnel 统一将流量转发到 `https://localhost:443`，由 Nginx 在容器内按路径分发：

- **Agent gRPC 通信**：`/proto.NezhaService/*` 走 `grpc_pass`，HTTP/2 多路复用 + keepalive。
- **WebSocket 长连接**：`/api/v1/ws/(server|terminal|file)` 走 `proxy_pass` 并透传 `Upgrade`/`Connection` 头，支持面板终端、文件管理、实时日志。
- **面板 HTTP/API 请求**：其余路径 `/` 反代到 `localhost:8008`（Dashboard）。

> ** 容器健康检查直接使用 **8008** 端口。

## 6.2 方案 A：单域名

Cloudflare Tunnel 配**一条规则**：

| 顺序 | Domain | Type | URL | 路径 |
|---|---|---|---|---|
| 1 | `nezha.nyc.mn` | HTTPS | `localhost:443` | `*` |

**其他应用程序设置 → TLS**：

| 选项 | 值 |
|---|---|
| 不进行 TLS 验证 | ✅ 开 |
| HTTP2 连接 | ✅ 开 |

- `ARGO_DOMAIN` = `nezha.nyc.mn`
- 浏览器打开 `https://nezha.nyc.mn` 就是面板
- Agent 连接 `nezha.nyc.mn:443`

## 6.3 方案 B：SaaS 自定义主机名

**关键概念先分清**：

| 概念 | 位置 | 作用 |
|---|---|---|
| **回退源** | Cloudflare for SaaS 的配置字段 | 告诉 Cloudflare 边缘节点「找不到更具体的自定义主机名时，去这条隧道」 |
| **Tunnel Public Hostname** | Tunnel 里的规则 | 按 Host + Path 匹配请求，决定落到容器哪个端口 |
| **`ARGO_DOMAIN`** | 环境变量 | Agent 连接的目标域名，**该域名必须在 Tunnel 里有一条对应规则** |

**回退源本身不是 Tunnel 规则**。真正生效的是 Tunnel 里的 Public Hostname 规则。

### B.1 Cloudflare for SaaS 设置

| 配置项 | 值 |
|---|---|
| 回退源 | `nezha.nyc.mn` |
| 自定义主机名 | `nezha.loc.cc`、`nezha.A.tw`、`nezha.B.kg`、`nezha.C.og` … |
| 每个自定义主机名 | 客户 CNAME 到 `nezha.nyc.mn` |

### B.2 Tunnel Public Hostname 规则

| 顺序 | Domain | Type | URL | 路径 | 说明 |
|---|---|---|---|---|---|
| 1 | `nezha.nyc.mn` | HTTPS | `localhost:443` | `*` | Agent 直连（`ARGO_DOMAIN`） |
| 2 | `nezha.loc.cc` | HTTPS | `localhost:443` | `*` | 面板/Agent共用 |
| 3 | `nezha.A.tw` | HTTPS | `localhost:443` | `*` | 面板/Agent共用 |
| 4 | `nezha.B.kg` | HTTPS | `localhost:443` | `*` | 面板/Agent共用 |
| … | 其他自定义主机名 | HTTPS | `localhost:443` | `*` | 每个域名一条 |

**每条规则**的其他应用程序设置 → TLS：

| 选项 | 值 |
|---|---|
| 不进行 TLS 验证 | ✅ 开 |
| HTTP2 连接 | ✅ 开 |

> **`nezha.nyc.mn` 这条规则要不要**：
> - 若 `ARGO_DOMAIN=nezha.nyc.mn`（常见选择），**必须有**，Agent 直连这个 host 时用它
> - 若用其他域名当 `ARGO_DOMAIN`，这条可选
> - **用户通过 SaaS 域名访问时，不会命中这条规则**（SaaS 回退保留 Host 头为 `nezha.loc.cc`）

### B.3 所有绑定域名的通用性

所有在 Tunnel 里绑定了规则的域名，均可同时用于：

- **面板访问**：浏览器打开 `https://<任意已绑定域名>/`
- **Agent 连接**：`ARGO_DOMAIN` 填任意已绑定域名，Agent 连接 `<该域名>:443`

> `ARGO_DOMAIN` 只需选一个域名填写即可，**该域名必须在 Tunnel 里有对应规则**。
> 通常填回退源域名 `nezha.nyc.mn`，这样 Agent 直连时走 Tunnel 里那条 `nezha.nyc.mn` 规则，不依赖 SaaS 链路，延迟更低、链路更短。

### B.4 流量路径

```
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
④ Cloudflare Tunnel（按 Host 匹配 ingress 规则）
        │ 命中 nezha.loc.cc * → https://localhost:443
        ▼
⑤ Nginx 443 端口按路径分发
        ├─ /proto.NezhaService/* → grpc_pass → localhost:8008（Agent gRPC）
        ├─ /api/v1/ws/*         → proxy_pass + Upgrade（WebSocket）
        └─ /                    → proxy_pass → localhost:8008（面板）
```

### B.5 维护口诀

> **加一个域名 = SaaS 加一条自定义主机名 + Tunnel 加一条对应规则（HTTPS localhost:443，开 TLS 跳过 + HTTP2）。**

## 6.4 两个方案对比

| 对比项 | 方案 A（单域名） | 方案 B（SaaS 多域名） |
|---|---|---|
| 适用场景 | 单个面板域名 | 多个自定义访问域名 |
| Tunnel 规则数 | 1 条 | 每个域名 1 条 |
| Type | HTTPS | HTTPS |
| URL | `localhost:443` | `localhost:443` |
| 不进行 TLS 验证 | ✅ 开 | ✅ 开 |
| HTTP2 连接 | ✅ 开 | ✅ 开 |
| 协议分发位置 | Nginx 443（按路径） | Nginx 443（按路径） |
| 新增域名时 | 不适用 | SaaS + Tunnel 各加一条 |

## 6.5 Cloudflare 侧必须开启 gRPC + WebSockets

进入 Cloudflare 仪表盘 → 选中回退源域名（如 `nezha.nyc.mn`）→ 左侧菜单 **网络**：

| 开关 | 作用 | 不开启的后果 |
|---|---|---|
| ✅ **gRPC** | Agent 通过 HTTP/2 gRPC 上报数据 | Agent 无法上报，面板显示探针离线 |
| ✅ **WebSockets** | 面板终端、文件管理、实时日志等长连接 | 终端连不上、文件管理打不开、实时数据不刷新 |

> 三个层面缺一不可：
> - **Tunnel 侧**：HTTP2 连接 + 不进行 TLS 验证，保证 Cloudflare 到容器走 HTTP/2；
> - **Nginx**：`grpc_pass` / `Upgrade` 头处理，容器内协议正确转发；
> - **Cloudflare 网络开关**：边缘网络放行 gRPC 和 WebSocket 升级。
>
> 方案 B 下，只需给回退源域名（`nezha.nyc.mn`）开启这两个开关，自定义主机名不需要单独开。

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

### 各脚本说明

| 脚本 | 说明 |
|---|---|
| `start.sh` | 容器入口。完成环境检查、SSL 证书生成、nginx 配置（仅 443）、主配置优化、二进制下载、服务启动、分支判断，最后进入每小时备份+更新循环 |
| `backup.sh` | 使用 `VACUUM INTO` / `.backup` 热备数据库，复制 `data/` 及 `config.yml`，清理旧 transfers 记录，ZIP 加密后上传 GitHub，维护 README，清理超出保留数量的旧备份 |
| `restore.sh` | 读取 README 判断手动标记/指定文件/最新文件，下载并验证 ZIP，兼容新旧两种目录格式解压，mv 备份现有数据（保留最近 1 份），恢复数据并清理 WAL/SHM |
| `renew.sh` | 对比本地与 GitHub Releases 最新版本，有新版则下载解压并重启 dashboard + agent |
| `restart.sh` | 停止并重启 dashboard，供手动调用 |

### 端口清单

| 端口 | 谁监听 | 用途 |
|---|---|---|
| **443** | Nginx | Tunnel 入口，TLS + 路径分发 |
| **8008** | Dashboard | 面板 HTTP/API + 容器健康检查 |

---

# 八、常见问题

| 问题 | 解决办法 |
|---|---|
| **首次安装后 GitHub 仓库没出现备份** | 检查 `GITHUB_TOKEN`、`GITHUB_REPO_OWNER`、`GITHUB_REPO_NAME`、`ZIP_PASSWORD` 是否正确，Token 是否有 `repo` 或 Contents 读写权限；也可手动把 README 改为 `backup` 重试 |
| **首次备份失败导致重启后 Agent 全部失联** | 说明 `agent_secret_key` 没被保存。重启后面板生成新 secret，需要重新添加 Agent；先手动触发备份再重启 |
| **备份里没有 `config.yml`，Agent 没启动** | 备份来自旧版本或其他项目。若想监控容器自己，设置 `NZ_UUID`，脚本会从恢复的 `data/config.yaml` 读 `agent_secret_key` 重新生成 `config.yml` |
| **跨项目迁移，备份结构不一样** | 支持标准结构 `data/sqlite.db` 和旧版结构根目录 `sqlite.db`；其他结构自动跳过且不破坏数据。可手动解压查看后适配 |
| **备份文件超过 47 MB（base64 后）** | `backup.sh` 会跳过上传并提示，建议减小 `TRANSFERS_KEEP_DAYS` 或 `BACKUP_KEEP_COUNT` |
| 面板打开但探针离线 | Cloudflare 未开启 gRPC：选择域名 → 网络 → 打开 gRPC 开关 |
| 面板打开但终端/文件管理连不上 | Cloudflare 未开启 WebSockets：同上位置打开 WebSockets 开关 |
| 面板打开但 Agent 离线 | 检查 `config.yml` 里的 `client_secret` 是否与 `data/config.yaml` 的 `agent_secret_key` 一致 |
| 恢复后 Agent 没启动 | 检查备份里是否有 `config.yml`；若没有，需设置 `NZ_UUID` 让脚本重新生成 |
| 手动备份没触发 | README 内容必须只有 `backup`（6 个字符，无多余空格换行） |
| 指定恢复没生效 | README 内容必须只有 `data-xxx.zip`，且该文件确实存在于仓库中 |
| 面板版本没更新 | `DASHBOARD_VERSION` 已设置会锁定版本，改为留空即可跟随最新 |
| Tunnel 配了 `https://localhost:443` 但连接失败 | 检查 Tunnel 侧是否开启「不进行 TLS 验证」和「HTTP2 连接」 |
| SaaS 客户域名访问 404 | 检查是否在 Tunnel 里为对应域名加了对应规则（HTTPS localhost:443） |
| 容器健康检查失败 | 健康检查目标改为 **8008** 端口 |
| 面板/Agent 无法访问 | 确认 Nginx 正在监听 443：`ss -tlnp \| grep 443` |
| agent 未下载/未启动 | `NZ_UUID` 或 `ARGO_DOMAIN` 任一未设置，`start.sh` 会跳过 agent 下载与启动 |

---

# 九、关键说明

| 项 | 说明 |
|---|---|
| `NZ_UUID` | 两个用途：① 首次安装生成 `config.yml`；② 备份里没有 `config.yml` 时重新生成 Agent 配置。有备份且备份含 `config.yml` 时不需要。`NZ_UUID` 或 `ARGO_DOMAIN` 任一缺失，agent 不会被下载或启动 |
| **首次安装自动备份** | 首次安装等待 50 秒（给用户改密码）后立即触发 `backup.sh`，建立「有备份」状态，之后所有启动都是常规模式 |
| 备份包中的 `config.yml` | Agent 配置的权威来源，恢复后覆盖容器内的；若备份不含，且设了 `NZ_UUID`，会重新生成 |
| 备份保留天数 | 只影响 `transfers` 表（流量记录），其他表完整保留 |
| 存储方式 | GitHub 仓库根目录的 `data-*.zip` 文件，通过 Contents API 上传；单文件 base64 后不超过 47 MB |
| nginx 监听端口 | **仅 443**（HTTPS + 自签名证书），80 端口已弃用 |
| nginx 生命周期 | 全程在线，只在启动时启一次，不随恢复流程重启 |
| nginx 主配置优化 | `worker_rlimit_nofile 65535`、`worker_connections 20480`、`http2_max_concurrent_streams 2048`，适配大量 Agent + WebSocket + gRPC 并发连接 |
| cloudflared 生命周期 | 全程在线，只在启动时启一次，使用 `--protocol http2` 运行 |
| dashboard 生命周期 | 首次启动 → 常规启动时杀一次 → 恢复后重启 |
| 容器健康检查 | 直连 **8008** 端口（Dashboard）|
| 旧数据归档 | 恢复前将现有 `/app/data` mv 为 `/app/data.bak.<timestamp>`，只保留最近 1 份 |
| **Cloudflare 网络开关** | **gRPC + WebSockets 都要打开**，缺一不可 |
| **Tunnel TLS 设置** | 不进行 TLS 验证 + HTTP2 连接，每条 Tunnel 规则都要开 |
| 进程日志脱敏 | `print_processes` 输出时自动将 `--token` 和 `TUNNEL_TOKEN=` 后的 Token 替换为 `***REDACTED***` |
| 日志格式 | `[时间] [级别] 内容`，级别 6 字符宽；`[STEP]` 标记大步骤，`└─` 表示子项 |
| 临时目录 | 下载/解压统一用 `/tmp/nezha-*`，退出时自动清理，`/app` 不残留 zip |

## 相关文件

| 文件 | 用途 |
|---|---|
| `/app/data/config.yaml` | 面板配置，含 `agent_secret_key` |
| `/app/data/sqlite.db` | 面板数据库 |
| `/app/config.yml` | Agent 配置，含 `client_secret` + `uuid` |
| `/app/nezha.pem` | Nginx 自签名证书（443 端口用） |
| `/app/nezha.key` | Nginx 自签名私钥（443 端口用） |
| `/app/data.bak.*` | 恢复前的旧数据，自动保留最近 1 份 |

---

**安全提示**：Cloudflare Tunnel Token、GitHub Token、ZIP 密码属于敏感信息，不要在日志、截图或公开渠道泄露。首次安装完成后立即修改面板默认密码（默认 `admin/admin`）。
