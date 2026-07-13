# ⭐ Star 星星走起 动动发财手点点 ⭐

## 在 Hugging Face 部署哪吒面板 V1 版（带自动备份功能）

> **重要提示**：本方案未使用 `OAuth 2.0` 登录（授权流程较繁琐），因此**安装完成后必须立即进入面板修改默认密码**以确保安全。

---

## 📋 必需环境变量配置示例

| 变量名                 | 示例值                             | 必填 | 说明                                                                               |
| ------------------- | ------------------------------- | -- | -------------------------------------------------------------------------------- |
| `ARGO_AUTH`         | `eyJhIjoi.......`               | ✅  | Argo Tunnel 认证 Token，从 [Cloudflare Tunnels](https://one.dash.cloudflare.com/) 获取 |
| `ARGO_DOMAIN`       | `nezha.com`                  | ✅  | 面板访问域名，同时用于探针上报                                                                  |
| `GITHUB_TOKEN`      | `ghp_xxxxxxxx`                  | ✅  | GitHub Token，用于配置文件自动备份到 GitHub                                                  |
| `GITHUB_REPO_OWNER` | `your_username`                 | ✅  | 备份仓库所有者                                                                          |
| `GITHUB_REPO_NAME`  | `nezha-backup`                  | ✅  | 存储配置备份的仓库名称 `注意配置私有仓库`                                                              |
| `GITHUB_BRANCH`     | `main`                          | ✅  | 备份使用的分支名称                                                                        |
| `ZIP_PASSWORD`      | `147369`                        | ✅  | 备份压缩包加密密码                                                                        |
| `NZ_UUID`           | `f8ff434*************62e0`      | ✅  |  在线生成访问:https://www.uuidgenerator.net/                                                           |
| `NZ_CLIENT_SECRET`  | `kDerKiyNp*************mvj0XMy` | ❌  | `自动生成` 备份文件中 `.yaml` 文件里的 `agentsecretkey` 参数                                           |
| `NZ_TLS`            | `true`                          | ❌  | 是否启用 TLS，默认 `true`                                                               |
| `DASHBOARD_VERSION` | `v1.14.1`                       | ❌  | 指定部署的探针版本，默认 `latest`                                                            |
| `PROJECT_URL` | `https://xxx.hf.space`                       | ❌  | 设置即启用保活，不设置则跳过                                                            |

---

## 🔧 Cloudflare Tunnel 配置

在运行项目之前，需要完成以下设置：

### 1. 开启 gRPC 流量代理

在 Cloudflare 中为你的域名**启用 gRPC 支持**。

### 2. 配置 Tunnel Public Hostname

设置参数如下：

- **Type**: `HTTPS`
- **URL**: `localhost:443`
- **Additional application settings**:
  - **TLS 设置**:
    - ✅ `No TLS Verify`（关闭 TLS 验证）
    - ✅ `HTTP2 connection`（启用 HTTP/2 连接）

> **重要**：完成配置后，记录下 Argo 域名和 Token，供后续使用。

---

## 🌐 访问说明

| 访问地址 | 说明 |
| --- | --- |
| **Hugging Face 分配的 URL** | 伪装页面（用于隐藏真实身份） |
| **Cloudflare 域名**（`ARGO_DOMAIN`） | **真实的哪吒面板访问地址** ⭐ |

> **提示**：请使用 Cloudflare 域名访问哪吒面板，Hugging Face 分配的 URL 仅作为部署容器的入口，不是面板的实际访问地址。

---

## 💾 触发备份
### 方法 1：自动备份
- 默认:凌晨4点自动备份

### 方法 2：手动备份 通过 GitHub 网页操作

1. 访问你的备份仓库
2. 打开或生建 `README.md` 文件
3. 点击右上角的编辑按钮（铅笔图标 ✏️）
4. 将文件内容**全部替换**为：`backup`
5. 点击 **"提交更改"** 提交
6. 等待最多 1 小时（守护进程每小时自动检查一次）

---

## 📁 项目文件说明

```
.
├── .github/workflows/
│   └── Packages.yml              # GitHub Actions 工作流
├── backup.sh                     # 配置备份脚本
├── restore.sh                    # 配置恢复脚本
├── Dockerfile                    # Docker 镜像定义
├── entrypoint.sh                 # 容器启动入口
├── main.conf                     # 主配置文件
├── ssl.conf.template             # SSL 配置模板
├── index.html                    # 伪装页面
├── 一步一步照着做教程.md          # 保姆级教程文档
└── README.md                     # 项目文档
```

| 文件 | 用途 | 备注 |
| --- | --- | --- |
| `Packages.yml` | GitHub Actions 工作流 | 自动生成并推送 Docker 镜像到 Packages |
| `backup.sh` | 配置备份脚本 | 定期备份哪吒面板配置到 GitHub |
| `restore.sh` | 配置恢复脚本 | 从备份恢复哪吒面板配置 |
| `Dockerfile` | Docker 镜像定义 | 定义容器构建规则和依赖 |
| `entrypoint.sh` | 容器启动入口 | 容器启动时执行的初始化脚本 |
| `main.conf` | 主配置文件 | 哪吒面板主要配置 |
| `ssl.conf.template` | SSL 配置模板 | Nginx SSL 配置模板文件 |
| `index.html` | 伪装页面 | **建议用 AI 生成自定义内容**，隐藏真实身份 |
| `README.md` | 项目文档 | 部署说明和使用指南 |

---

## 🚀 快速开始

### 第 1 步：Fork 仓库

点击右上角 **Fork** 按钮，将项目复制到你的账户。

### 第 2 步：启用 GitHub Actions

1. 进入 **Actions** 选项卡
2. 点击 **I understand my workflows**
3. 构建自己的镜像

### 第 3 步：查看镜像地址

1. 进入 **Packages** 页面
2. 找到镜像地址，例如：`docker pull ghcr.io/oyz8/nz:latest`
3. 记录此地址

### 第 4 步：配置 Hugging Face 变量

1. 登录 [Hugging Face](https://huggingface.co/)
2. 创建新的 Space（选择 Docker 模板）
3. 在 **Settings** → **Repository secrets** 中添加所有必需的环境变量（见上表）

### 第 5 步：添加 Dockerfile

在 Hugging Face Space 中添加 `Dockerfile` 文件，内容如下：

```dockerfile
FROM ghcr.io/oyz8/nz:latest
```

### 第 6 步：查看部署日志

1. 进入 **Logs** 页面，查看部署进度。
2. 部署成功后，使用 Cloudflare 分配的域名（即环境变量 `ARGO_DOMAIN` 的值）访问面板。
3. **保活提醒**：HuggingFace Space 需要保持活跃以防休眠，请自行处理保活，或通过设置 `PROJECT_URL` 变量来实现自动保活。
4. **哪吒面板设置 Telegram 通知收不到 ？**  
   这是 HuggingFace 的常见网络限制，无法直接访问 `api.telegram.org`。你必须配置一个反代地址。可使用:[Cloudflare Workers 自建反代脚本](https://raw.githubusercontent.com/oyz8/LemeHost/refs/heads/main/_worker.js)

- URL如下
```URL
https://xxx.xxx.workers.dev/bot123456789:Assssssssssssssssssssk/sendMessage
```
- 请求方式:POST
- 类型:JSON
- 请求体如下
```请求体
{
    "chat_id": "123456789",
    "text": "🔰 *探针警报*\n\n*来自*: \" *#SERVER.NAME# *\"\n*#NEZHA#*\n\n*时间*： *#DATETIME# *",
    "parse_mode": "Markdown",
    "reply_markup": {
        "inline_keyboard": [
            [
                {
                    "text": " 探针仪表盘",
                    "url": "https://nezha.com"
                }
            ]
        ]
    }
```
- 勾选:验证TLS

---

### *祝部署顺利！* 🎉




