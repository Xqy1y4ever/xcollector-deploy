# Xcollector Deploy

Xcollector 的**部署入口**。两个栈，各自独立：

```
┌─ backend/ ─────────────────────────┐   ┌─ bot/ ──────────────────────────┐
│ 数据层（SQLite + 附件）             │   │ 消息处理层（连 OneBot / 抽取）    │
│ ./start.sh   ./stop.sh   ./preflight.sh │  ./start.sh [client]  ./stop.sh │
│ 自己的 .env                         │   │ 自己的 .env                      │
└─────────────────────────────────────┘   └─────────────────────────────────┘
        ▲                                            │
        └──────── Docker 网络 xcollector ◀───────────┘
                 （backend 建，bot 用）
```

- **不共用任何文件**：各自的 `.env`、各自的脚本、各自的配置说明。
- **不用 compose**：一个容器 + 一张网络 + 一个卷，本来就是 `docker run` 一句话。
  脚本只是把「建网络 / 建卷 / 起容器 / 等健康检查」串起来，等价命令 README 里都有。
- 两者之间只有两样东西连着：网络 `xcollector`（backend 建）和 `API_TOKEN`（两边同一个值）。
- **前端不在这里**：`xcollector-web` 只产出 `dist/`，由你自己的 web server 托管，
  加一条 `/api` 反代（见下面「托管 dist」）。
- 源码仓库：[backend](https://github.com/Xqy1y4ever/xcollector-backend) ·
  [bot](https://github.com/Xqy1y4ever/xcollector-bot) ·
  [client](https://github.com/Xqy1y4ever/xcollector-client) ·
  [web](https://github.com/Xqy1y4ever/xcollector-web)

## 部署

### 前置

| | |
|---|---|
| Docker | 20.10+（只要 `docker`，不需要 compose） |
| NapCat | 已安装并登录 QQ（接法见「接 NapCat」） |
| 前端 | `xcollector-web` 的 `dist/`（见「托管 dist」） |
| 端口 | 默认占宿主机 `8000`（后端）、`8082`（bot 管理接口）、`8081`（反向 OneBot，仅 server 模式） |

### 一条龙

```bash
git clone https://github.com/Xqy1y4ever/xcollector-deploy.git
cd xcollector-deploy

# 1) 先起数据层
cd backend
cp .env.example .env
#    改：API_TOKEN（生成一个随机串）、SIGNUP_MODE（默认邀请码制）
./preflight.sh          # 只读检查：docker、.env、端口、镜像
./start.sh              # 建网络与卷 → 起容器 → 等健康检查通过

# 2) 再起消息处理层
cd ../bot
cp .env.example .env
#    改：API_TOKEN（**与上面同一个值**）、GROUP_WHITELIST、SENDER_WHITELIST、ONEBOT_WS_URL
./preflight.sh
./start.sh

# 3) 把 dist/ 交给你的 web server（见「托管 dist」），打开页面注册
```

> 脚本带可执行位，直接 `./start.sh`。**如果报 `Permission denied`**，说明你的克隆里
> 少了可执行位（Windows 上克隆、或旧版本的仓库会这样），二选一：
> `chmod +x backend/*.sh bot/*.sh`，或者在任何地方都用 `sh ./start.sh`。

生成服务令牌：

```bash
python3 -c "import secrets;print(secrets.token_hex(32))"
```

**顺序有讲究**：网络 `xcollector` 由 backend 的 `start.sh` 创建，bot 靠它用服务名
`backend` 找到后端。先起 bot 会直接报「找不到网络」并告诉你该去哪个目录。（后端没
起来时 bot 也不会崩，只是头几秒的调用会失败、稍后自己接上。）

---

## 栈 1：backend（数据层）

存通知、附件、用户、订阅，并提供 HTTP 接口。它不认识 QQ、OneBot、LLM 这些词。

```bash
cd backend
cp .env.example .env
vi .env                 # 至少填 API_TOKEN
./preflight.sh
./start.sh
```

### 配置（`backend/.env`）

| 变量 | 默认 | 说明 |
|---|---|---|
| `API_TOKEN` | 空 | **服务令牌**，只有 bot 与你的运维命令用。**必须与 `bot/.env` 里同一个值。** 留空 = 不校验（仅本机开发） |
| `SIGNUP_MODE` | `invite` | `invite` = 注册要邀请码（用 `API_TOKEN` 调 `POST /api/invites` 签发）；`open` = 谁都能注册 |
| `BACKEND_HOST_PORT` | `8000` | 宿主机端口（反代指这里）。被占时改它，**不影响 bot**（容器之间走内部网络） |
| `BACKEND_BIND` | `127.0.0.1` | 监听地址。web server 在别的机器上时才改 `0.0.0.0`（后端不带 TLS，先想清楚边界） |
| `BACKEND_VOLUME` | `xcollector_backend-data` | 数据卷名（SQLite 库 + 附件）。换名字等于换一份数据 |
| `IMAGE_BACKEND` / `VERSION` / `PULL_POLICY` | GHCR / `latest` / `always` | 镜像与升级策略 |
| `MEDIA_MAX_BYTES` | `5242880` | 附件字节上限。**要和 `bot/.env` 对齐**，否则 bot 下载了却被后端 413 |
| `ATTACHMENT_URL_TTL` | `3600` | 附件签名链接有效期（秒）。设 0 会让证据图 401 |
| `ATTACHMENT_SIGN_KEY` | 空 | 留空 = 从 `API_TOKEN` 派生 |
| `VERIFY_CODE_TTL` / `VERIFY_MAX_ATTEMPTS` | `600` / `5` | QQ 验证码有效期与允许猜错次数 |
| `ALLOW_TOKEN_ROTATION` | `true` | 允许老用户重新要码换令牌 |
| `CORS_ORIGINS` | 空 | 前后端**不同源**时才需要；同源反代留空 |
| `LOG_LEVEL` / `TZ` | `INFO` / `Asia/Shanghai` | 日志级别、时区（与 bot 保持一致） |

签发邀请码（`SIGNUP_MODE=invite` 时）：

```bash
curl -X POST http://127.0.0.1:8000/api/invites \
  -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json" \
  -d '{"note":"给谁的","max_uses":1}'
```

### 确认在跑 / 常用命令

```bash
docker exec xcollector-backend python -c "import urllib.request,os;print(urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8000/api/health',headers={'Authorization':'Bearer '+os.environ.get('API_TOKEN','')})).status)"
docker logs -f xcollector-backend
./stop.sh                 # 停（数据在卷里，不会丢）
```

### 不用脚本的话

```bash
docker network create xcollector
docker volume create xcollector_backend-data
docker run -d --name xcollector-backend --restart unless-stopped \
  --network xcollector --env-file .env \
  -e DB_PATH=data/xcollector.db -e ATTACHMENT_DIR=data/attachments \
  -e SERVER_HOST=0.0.0.0 -e SERVER_PORT=8000 \
  -p 127.0.0.1:8000:8000 -v xcollector_backend-data:/app/data \
  --security-opt no-new-privileges:true \
  ghcr.io/xqy1y4ever/xcollector-backend:latest
```

---

## 栈 2：bot（消息处理层）

连 OneBot(NapCat)、按白名单收消息、抽取通知与截止时间、下载附件、按订阅扇出、
发每日摘要、处理私聊指令（含 `/注册`）。它是整套系统里唯一做业务判断的地方。

```bash
cd bot
cp .env.example .env
vi .env                 # API_TOKEN 填同一个值；两个白名单必填；ONEBOT_WS_URL 指向 NapCat
./preflight.sh
./start.sh
```

### 配置（`bot/.env`）

完整说明见 [`bot/.env.example`](bot/.env.example)。关键项：

| 变量 | 默认 | 说明 |
|---|---|---|
| `API_TOKEN` | 空 | 与 `backend/.env` **同一个值**（不一致 → 全部 401） |
| `BACKEND_BASE_URL` | `http://backend:8000` | 走内部网络的服务名；后端在别的机器上时换成那台的地址 |
| `ONEBOT_MODE` / `ONEBOT_WS_URL` / `ONEBOT_ACCESS_TOKEN` | `client` / `host.docker.internal:3001` / 空 | OneBot 连接方式与凭据 |
| `GROUP_WHITELIST` | 空 | 要处理的群，`群号:名称,群号:名称`。**留空 = 一个消息都不处理** |
| `SENDER_WHITELIST` | 空 | 要处理的发送者，`QQ号:名称`。**留空 = 一个消息都不处理** |
| `SENDER_WHITELIST_MODE` | `strict` | `off` = 该群里谁发的都算（**显式**放开） |
| `EXTRACTOR` | `llm` | `rule` 只跑规则（不花钱）/ `llm` / `both` |
| `LLM_PRIMARY_PROVIDER` / `LLM_PRIMARY_MODEL` | `deepseek` / `deepseek-chat` | 主模型；自建端点填 `LLM_PRIMARY_API_BASE` + `_API_KEY` |
| `DEEPSEEK_API_KEY`（或对应提供商的 key） | 空 | 用 `llm`/`both` 才需要 |
| `VLM_ENABLED` | `false` | 把图片也喂给模型 |
| `DIGEST_ENABLED` / `DIGEST_TIME` | `true` / `21:30` | 每日摘要；`DIGEST_TARGET_QQ` 留空 = 每个用户各收自己那份 |
| `COMMAND_WHITELIST` | 空 | 允许发指令的 QQ。**留空 = 除 `/注册`、`/help` 外谁都不能发指令** |
| `BOT_HOST_PORT` / `BOT_BIND` | `8082` / `127.0.0.1` | 管理接口端口。**不要反代到公网** |
| `ONEBOT_HOST_PORT` | `8081` | 仅 `ONEBOT_MODE=server` 时用 |

> **两个白名单都是 fail-closed**：留空 = 一个消息都不处理，启动日志会明确警告。
> 另外它们只决定 **bot 看得见什么**；用户订阅决定 **抽什么**，两者都要满足。

### 接 NapCat

**A. 正向 WS（推荐）**

```env
ONEBOT_MODE=client
ONEBOT_WS_URL=ws://host.docker.internal:3001    # 容器里连宿主机的 NapCat
ONEBOT_ACCESS_TOKEN=                            # 与 NapCat 里配的一致；留空=不校验
```

`start.sh` 已经加了 `--add-host host.docker.internal:host-gateway`，Linux 上也能用这个名字。
NapCat 在别的机器上就直接写那台的地址。

**B. 反向 WS**

```env
ONEBOT_MODE=server
ONEBOT_LISTEN_HOST=0.0.0.0
ONEBOT_LISTEN_PORT=8081
ONEBOT_LISTEN_PATH=/onebot/ws
```

NapCat 里填 `ws://<部署机>:8081/onebot/ws`。

### 离线客户端（可选，`./start.sh client`）

不连 QQ 也能入库：客户端读一份聊天记录库，抽取后写进后端。它和 bot 是**二选一**的
两条入库链路（同一条消息会被两边各收一份、message_id 格式还不同，幂等键拦不住）。

```env
CLIENT_TOKEN=xc_...                 # 某个用户的 UserToken（不是 API_TOKEN）
CLIENT_NT_MSG_HOST_DIR=/绝对路径/nt_db   # 放 nt_msg.db（或 nt_msg_export.db）的目录
CLIENT_NT_MSG_KEY=<16 个 ASCII 字符>     # A 方案需要，见下
```

```bash
./start.sh client
```

用 A 方案（给加密的 `nt_msg.db`）时，第一次先看一遍解密报告（不连后端、不花模型的钱）：

```bash
./stop.sh client
docker run --rm --network xcollector -v /绝对路径/nt_db:/data/nt:rw \
  --env-file .env ghcr.io/xqy1y4ever/xcollector-client:latest --prepare
```

**密钥从哪来**：NTQQ 解密那个库用的 **16 个 ASCII 字符**，只在进程内存里。
用 [`QQBackup/qq-win-db-key`](https://github.com/QQBackup/qq-win-db-key)
（或 `nt_msg_db_util/getkey.ps1`）读出来；换账号/换机器要重取。
别写进 README/聊天记录，放 `.env`（已 gitignore）或用 `CLIENT_NT_MSG_KEY_FILE`。

### 确认在跑 / 常用命令

```bash
docker logs -f xcollector-bot        # 每条消息的处理轨迹；连不上 NapCat 也在这里
curl -H "Authorization: Bearer $API_TOKEN" http://127.0.0.1:8082/api/status
docker exec xcollector-bot python -m app.tools.check_llm     # 模型配置能不能用（联网）
./stop.sh                # 停 bot（没有需要保留的本地状态）
./stop.sh client         # 停客户端
```

### 不用脚本的话

```bash
docker run -d --name xcollector-bot --restart unless-stopped \
  --network xcollector --env-file .env \
  -e BACKEND_BASE_URL=http://backend:8000 \
  -e BOT_LISTEN_HOST=0.0.0.0 -e BOT_LISTEN_PORT=8082 \
  -e ONEBOT_LISTEN_HOST=0.0.0.0 \
  -p 127.0.0.1:8082:8082 -p 127.0.0.1:8081:8081 \
  --add-host host.docker.internal:host-gateway \
  --security-opt no-new-privileges:true \
  ghcr.io/xqy1y4ever/xcollector-bot:latest
```

## 托管 dist

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

**托管它** —— 两条规则：`/` 静态文件 + SPA fallback；`/api/` 反代到
`127.0.0.1:8000`（前缀保留、**原样转发 `Authorization`**）。

> **不要反代 `/bot`（8082）**：那是 bot 的管理接口，只认管理令牌 —— 拿到它等于拿到
> 「以 bot 身份读写所有人的数据 + 直接往 QQ 发消息」的能力。要在浏览器里看那一页，
> 就在本机跑 `npm run dev`（dev 代理保留了 `/bot`）。

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
人工修正都是写操作。

## 从源码构建（可选）

不用 GHCR 的话，在四个仓库的同级目录里各 build 一次，把镜像名替换成 `IMAGE_*` 里那个：

```bash
docker build -t ghcr.io/xqy1y4ever/xcollector-backend:latest ../xcollector-backend
docker build -t ghcr.io/xqy1y4ever/xcollector-bot:latest     ../xcollector-bot
docker build -t ghcr.io/xqy1y4ever/xcollector-client:latest  ../xcollector-client
```

（前端不在这里：`npm ci && npm run build` 之后托管 `dist/`。）

## 数据与备份

唯一不可再生的东西都在数据卷里（SQLite 库 + 附件）：

```bash
# 备份
docker run --rm -v xcollector_backend-data:/data -v "$PWD":/backup alpine \
  tar czf /backup/xcollector-$(date +%F).tar.gz -C /data .

# 恢复
docker run --rm -v xcollector_backend-data:/data -v "$PWD":/backup alpine \
  tar xzf /backup/xcollector-YYYY-MM-DD.tar.gz -C /data
```

清空重来（**会删掉全部数据**）：

```bash
./backend/stop.sh && docker volume rm xcollector_backend-data
```

## 升级

```bash
cd backend && ./start.sh      # PULL_POLICY=always 时会先拉最新镜像
cd ../bot  && ./start.sh
```

后端启动时自动做数据库增量迁移，老库直接升上来。固定版本更稳：把两个 `.env` 里的
`VERSION` 改成某个 `sha-xxxxxxx` / `v1.2.3`，并把 `PULL_POLICY` 设成 `never`。

**从旧的单文件 compose 编排迁过来**：先停掉旧的容器，否则容器名会冲突。

```bash
# 在旧的 xcollector-deploy 根目录
docker compose down            # 数据在同一个卷 xcollector_backend-data 里，不会丢
# 再按上面的「一条龙」起两个栈
```

## 排查

先跑各自的 `./preflight.sh` —— 端口占用、`.env` 缺项、两边 `API_TOKEN` 是否一致、
容器里实际拿到的值 vs `.env` 里的值，它都会列出来。

| 现象 | 原因与处理 |
|---|---|
| `./start.sh: Permission denied` | 克隆里少了可执行位（Windows 上克隆会这样）。`chmod +x backend/*.sh bot/*.sh`，或直接用 `sh ./start.sh` |
| `start.sh` 报「找不到 Docker 网络 xcollector」 | 还没起 backend。`cd ../backend && ./start.sh` |
| **改了 `.env` 但不生效** | 容器的环境变量在**创建那一刻**就固定了。`./start.sh` 会重建容器（数据在卷里），`docker restart` 不会重读 `.env` |
| 端口被占 / 容器起不来 | `./preflight.sh` 会告诉你是谁占的；或在 `.env` 里改 `BACKEND_HOST_PORT` / `BOT_HOST_PORT` |
| 拉镜像报 `denied` / `manifest unknown` | GHCR 上的包是 private 而部署机没登录，或镜像名含大写 |
| 页面显示「bot 未运行或不可达」 | `docker logs xcollector-bot`，多半是 `ONEBOT_WS_URL` 连不上 NapCat |
| 日志里「已连接」之后立刻断开 | NapCat 的 WS 配了 Token 而 `ONEBOT_ACCESS_TOKEN` 没填/不一致 |
| 页面能开但列表空、状态页说「后端不可达」 | backend 没起来，或两个 `.env` 的 `API_TOKEN` 不一致 |
| bot 连上了但什么都不做 | 两个白名单留空 = 一个消息都不处理（fail-closed）。`./preflight.sh` 会点出来 |
| 证据图片显示不出来 | `ATTACHMENT_URL_TTL=0`，签名链接失效 |
| 客户端说「密钥不对 / 解不开」 | 密钥不是这个 QQ 账号的，或抄错了；用 `--prepare` 看它试过哪些参数 |

## 安全默认值

- `COMMAND_WHITELIST` 留空 = 除 `/注册`、`/help` 外谁都不能发指令；
- `API_TOKEN` 留空时后端不校验任何请求（启动时警告）—— 只适合完全可信的本机；
- 三个容器都只绑 `127.0.0.1`，对外只有你自己的反向代理；
- 容器都带 `no-new-privileges`；只有 backend 有持久卷。

## 许可

MIT
