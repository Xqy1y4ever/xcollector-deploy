# Xcollector Deploy

Xcollector 的**部署入口**：用 Docker Compose 把
[后端](https://github.com/Xqy1y4ever/xcollector-backend) 与
[bot](https://github.com/Xqy1y4ever/xcollector-bot)（可选再加
[离线客户端](https://github.com/Xqy1y4ever/xcollector-client)）编排起来。

```
QQ ──▶ NapCat ──OneBot──▶ bot ──┐
                                ├──▶ backend（SQLite + 附件，都在命名卷里）
nt_msg.db ──▶ client ───────────┘        ▲
                                         │ /api
浏览器 ──▶ 你自己的 web server（托管 xcollector-web 的 dist/）
```

- **前端不在这里**：`xcollector-web` 只产出 `dist/`，由你自己的 web server 托管
  （片段见下面「托管 dist」）。
- 两个源码仓库的镜像由各自的 CI 推到 GHCR，这里只负责拉与编排。
- 编排文件：[`docker-compose.yml`](docker-compose.yml)（拉镜像）、
  [`docker-compose.build.yml`](docker-compose.build.yml)（从源码构建）。

## 部署

### 前置

| | |
|---|---|
| Docker | 24+，带 compose v2 |
| NapCat | 已安装并登录 QQ（接法见下面「接 NapCat」） |
| 前端 | `xcollector-web` 的 `dist/`（见「托管 dist」） |
| 端口 | 默认占用宿主机 `8000`（后端）、`8082`（bot）、`8081`（反向 OneBot，仅 server 模式） |

### 快速开始

```bash
git clone https://github.com/Xqy1y4ever/xcollector-deploy.git
cd xcollector-deploy
cp .env.example .env
```

至少要改这几项（完整的项见 [`.env.example`](.env.example)，每一项都有说明）：

| 配置 | 说明 |
|---|---|
| `API_TOKEN` | **服务令牌**，只有 bot 用。生成：`python3 -c "import secrets;print(secrets.token_hex(32))"` |
| `GROUP_WHITELIST` | 要处理的群，格式 `群号:名称,群号:名称` |
| `SENDER_WHITELIST` | 要处理的发送者，格式 `QQ号:名称` |
| `ONEBOT_MODE` / `ONEBOT_WS_URL` | 见「接 NapCat」 |
| `SIGNUP_MODE` | `invite`（默认，要邀请码）或 `open` |
| `COMMAND_WHITELIST` | 允许发指令的 QQ 号，`QQ号:备注`。**留空 = 除 `/注册`、`/help` 外谁都不能发指令**（这两个是注册入口，不受限制） |

> **两个白名单都是 fail-closed：留空 = 一个消息都不处理**，启动日志会明确警告。
> 想让某个群里谁发的都收，把 `SENDER_WHITELIST_MODE` 设成 `off`（显式放开）。

> **用户登录用的不是上面任何一个令牌。** 每个人在 QQ 里给机器人发 `/注册` 拿验证码，
> 再到网页上用「QQ 号 + 验证码 + 邀请码」注册，系统给他一个 `xc_` 开头的
> **UserToken** —— 那是他的登录凭证，也是他调后端的唯一凭证。

```bash
sh preflight.sh          # 预检：只读，不拉镜像不起容器；有问题一次列完
docker compose pull
docker compose up -d
docker compose ps
```

然后把 `dist/` 交给 web server、加一条 `/api` 反代（见下），打开页面注册即可。

### 接 NapCat

NapCat 面板里开一个 WebSocket 服务，然后：

**A. 正向 WS（推荐）**

```env
ONEBOT_MODE=client
ONEBOT_WS_URL=ws://host.docker.internal:3001     # 容器里连宿主机的 NapCat
ONEBOT_ACCESS_TOKEN=                             # 与 NapCat 里配的一致；留空=不校验
```

```bash
docker compose up -d bot
```

**B. 反向 WS**（NapCat 连过来）

```env
ONEBOT_MODE=server
ONEBOT_LISTEN_HOST=0.0.0.0
ONEBOT_LISTEN_PORT=8081
ONEBOT_LISTEN_PATH=/onebot/ws
```

NapCat 那边填 `ws://<部署机>:8081/onebot/ws`（`ONEBOT_HOST_PORT` 可改宿主机端口）。

连不上不会让 bot 崩，只是收不到消息；状态见网页「系统状态」页或
`curl -H "Authorization: Bearer $API_TOKEN" http://127.0.0.1:8082/api/status`。

### 托管 dist

**拿到 dist**（部署机上不需要 Node）：

```bash
# 方式一：Release 附件
curl -L https://github.com/Xqy1y4ever/xcollector-web/releases/latest/download/dist.tar.gz \
  | tar xz -C /var/www/xcollector

# 方式二：GHCR 的文件镜像（FROM scratch 的"文件袋"，只能 docker cp，不能 docker run）
docker pull ghcr.io/xqy1y4ever/xcollector-web:latest
docker create --name xcw ghcr.io/xqy1y4ever/xcollector-web:latest
docker cp xcw:/dist/. /var/www/xcollector/dist/
docker rm xcw
```

**托管它** —— 关键是两条规则：`/` 静态文件 + SPA fallback；`/api/` 反代到
`127.0.0.1:8000`（前缀保留、**原样转发 `Authorization`**）。

> **不要加 `/bot/` 反代**：那是 bot 的管理接口，只认管理令牌（拿到它等于拿到
> 「以 bot 身份读写所有人的数据 + 直接往 QQ 发消息」）。要在浏览器里看那一页，
> 只在**本机**跑 `npm run dev`（dev 代理保留了 `/bot`）。

```nginx
server {
    listen 80;
    server_name _;
    root /var/www/xcollector/dist;
    index index.html;
    client_max_body_size 8m;

    location /assets/ { expires 1y; add_header Cache-Control "public, immutable"; try_files $uri =404; }
    location /        { try_files $uri $uri/ /index.html; }
    location /api/ {
        proxy_pass http://127.0.0.1:8000;      # 结尾不带 /，前缀保留
        proxy_set_header Host $host;
        proxy_set_header Authorization $http_authorization;   # 用户的 UserToken 在这个头里
    }
}
```

```caddy
:80 {
    root * /var/www/xcollector/dist
    encode gzip
    handle /api/* { reverse_proxy 127.0.0.1:8000 }
    handle { try_files {path} /index.html
             file_server }
}
```

不要限制成"只允许 GET"：注册（`POST /api/register`，且不带令牌）、订阅增删改、
人工修正都是写操作，权限由后端的 UserToken 判定。

### 入库客户端（可选）

不连 QQ 也能入库：客户端读一份聊天记录库，抽取后写进后端。它是**可选**的，
用 compose profile 关着 —— 因为它等于开了**第二条入库链路**，必须由人明确选。

| | |
|---|---|
| 输入 | A 方案：加密的 `nt_msg.db`（客户端自己剥头 + 解密 + 导出）；B 方案：现成的 `nt_msg_export.db` |
| 挂载 | 一个**读写**目录 `/data/nt`（A 方案的产物写在 `nt_msg.db` 旁边） |
| 令牌 | `CLIENT_TOKEN` = **某个用户的 UserToken**（不是 `API_TOKEN`） |

```env
CLIENT_NT_MSG_HOST_DIR=/绝对路径/nt_db        # 放 nt_msg.db（或 nt_msg_export.db）的目录
CLIENT_NT_MSG_KEY=<16 个 ASCII 字符的密钥>     # A 方案需要；见下「密钥从哪来」
CLIENT_TOKEN=xc_...
```

```bash
docker compose --profile client run --rm client --prepare   # 只看解密+导出报告，不连后端
docker compose --profile client up -d
```

B 方案把 `nt_msg_export.db` 放进同一个目录，并把
`CLIENT_DB_PATH=/data/nt/nt_msg_export.db`。

**密钥从哪来**：NTQQ 解密那个库用的 **16 个 ASCII 字符**，只在进程内存里。
用 [`QQBackup/qq-win-db-key`](https://github.com/QQBackup/qq-win-db-key)
（或 `nt_msg_db_util/getkey.ps1`）读出来。换账号/换机器要重取。
⚠️ 别写进 `docker-compose.yml`、别做成 build-arg（镜像层里谁都能看到），
放 `.env`（已 gitignore）或用 `CLIENT_NT_MSG_KEY_FILE` 指向一个挂载进来的文件。

### ⚠️ 同一个账号只能有一条入库链路

bot 和客户端同时入库会重复：同一条消息两边的 `message_id` 格式不同
（bot 用 OneBot 的，客户端用 `ntqq:<msg_id>`），幂等键拦不住，于是变成两条记录。
只想用客户端的话，把 `GROUP_WHITELIST` 与 `SENDER_WHITELIST` 留空
（bot 就不处理任何消息），它仍然负责 `/注册`、`/订阅`、摘要推送。

### 镜像与版本

```env
IMAGE_BACKEND=ghcr.io/xqy1y4ever/xcollector-backend
IMAGE_BOT=ghcr.io/xqy1y4ever/xcollector-bot
IMAGE_CLIENT=ghcr.io/xqy1y4ever/xcollector-client
VERSION=latest          # 或固定成 sha-xxxxxxx / v1.2.3
PULL_POLICY=missing     # missing=本地没有才拉；always=每次 up 都拉
```

> 镜像路径必须**全小写**（GHCR 不接受大写）。首次推送后要去 Packages 页面设可见性；
> 设成 private 的话部署机要先 `docker login ghcr.io`。

从源码构建（四个仓库放在同级目录）：

```bash
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

### 数据与备份

唯一不可再生的东西都在 `backend-data` 这个命名卷里（SQLite 库 + 附件）：

```bash
docker run --rm -v xcollector_backend-data:/data -v "$PWD":/backup alpine \
  tar czf /backup/xcollector-$(date +%F).tar.gz -C /data .

# 恢复
docker run --rm -v xcollector_backend-data:/data -v "$PWD":/backup alpine \
  tar xzf /backup/xcollector-YYYY-MM-DD.tar.gz -C /data
```

`bot` 与 `client` 容器**没有卷**（client 的状态库在源库旁边那个挂载目录里）。

### 升级

```bash
docker compose pull
docker compose up -d
```

后端启动时自动做数据库增量迁移，老库直接升上来。固定版本更稳：把 `VERSION`
从 `latest` 改成某个 `sha-xxxxxxx` / `v1.2.3`，配合 `PULL_POLICY=missing`。

### 排查

```bash
sh preflight.sh                      # 端口占用、.env 完整性、镜像可达、容器里实际拿到的值
docker compose logs -f bot           # 每条消息的处理轨迹
docker compose logs -f backend
docker compose exec backend python -m tests.check_config
docker compose exec bot python -m app.tools.check_llm    # 模型配置能不能用（联网）
```

| 现象 | 原因与处理 |
|---|---|
| **改了 `.env` 但不生效** | 容器的环境变量在**创建那一刻**就固定了。`docker compose restart` 不会重读 `.env`。用 `docker compose up -d --force-recreate bot` |
| `up` 报 `address already in use` | 宿主机端口被占（`preflight.sh` 会告诉你是谁占的），或在 `.env` 里改 `BACKEND_HOST_PORT` / `BOT_HOST_PORT` |
| `pull` 报 `denied` / `manifest unknown` | GHCR 上的包是 private 而部署机没登录，或镜像名含大写 |
| 页面显示「bot 未运行或不可达」 | `docker compose logs bot`，多半是 `ONEBOT_WS_URL` 连不上 NapCat |
| 日志里「已连接」之后立刻断开 | NapCat 的 WS 配了 Token 而 `ONEBOT_ACCESS_TOKEN` 没填/不一致 |
| 页面能开但列表空、状态页说「后端不可达」 | backend 没起来，或 `.env` 与 backend 的 `API_TOKEN` 不一致 |
| 状态页报错但通知列表正常 | 反代把 `/bot` 暴露了或没摘前缀（`/api` 不用摘，所以只有状态页坏） |
| 证据图片显示不出来 | `ATTACHMENT_URL_TTL` 被设成 0，附件签名链接失效 |
| 客户端说「密钥不对 / 解不开」 | 密钥不是这个 QQ 账号的，或抄错了；跑 `--prepare` 看它试过哪些参数 |

### 安全默认值

- `COMMAND_WHITELIST` 留空 = 除 `/注册`、`/help` 外**谁都不能发指令**；
- `API_TOKEN` 留空时后端不校验任何请求（启动时警告）—— 只适合完全可信的本机；
- backend / bot 只绑 `127.0.0.1`，对外只有你自己的反向代理；
- 容器都带 `no-new-privileges`；只有 backend 有持久卷。

## 许可

MIT
