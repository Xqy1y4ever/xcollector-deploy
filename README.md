# Xcollector

把 QQ **官方通知群**里的消息，自动整理成**带截止时间的任务条目**，发布到网页上给你看。

群里的通知常常被闲聊淹没，一条 DDL 又可能散在几条消息里 —— 逐条爬楼的注意力成本
高于信息本身的价值。Xcollector 把这件事自动化：接一个 QQ 机器人，自动筛选、
抽取、归档，并每天推一份摘要回群里。

> 本仓库（`xcollector-deploy`）既是 Xcollector 的**项目主页**，也是**部署入口** ——
> 用 Docker Compose 把整套系统跑起来看这里就够了。

## 它解决什么问题

官方通知发在几个固定群、由固定几个发布者发出。系统的输出是**任务条目**：
含截止时间、地点、详细说明，并且**旁边永远能看到它依据的原文**。

精度要求很高 —— 一个错的截止时间比没有截止时间更糟，因为它会被信任。
所以整套系统围绕一个目标设计：**LLM 可以出错，但不能静默出错**。

## 四个仓库

| 仓库 | 技术栈 | 职责 |
|---|---|---|
| [`xcollector-bot`](https://github.com/Xqy1y4ever/xcollector-bot) | Python 3.12 · FastAPI · websockets | **处理消息**：接 OneBot、筛选、抽取任务与截止时间、下载附件、检测缺口、推送摘要、接受私聊指令 |
| [`xcollector-backend`](https://github.com/Xqy1y4ever/xcollector-backend) | Python 3.12 · FastAPI · SQLite | **数据层**：存储与增删查改、附件存取 |
| [`xcollector-web`](https://github.com/Xqy1y4ever/xcollector-web) | Vue 3 · Element Plus · Pinia · Vite | **通知台**：按截止时间排序展示、解析结果与原文对照、人工修正。只产出 `dist/`，不参与运行时 |
| `xcollector-deploy` ← 你在这里 | Docker Compose | **部署入口**：编排后端与 bot；前端产物由你自己的 web server 托管 |

三个服务之间唯一的约定是接口契约
[`xcollector-backend/docs/api.md`](https://github.com/Xqy1y4ever/xcollector-backend/blob/main/docs/api.md)。

## 架构

```
QQ 群 ──▶ NapCat ──OneBot──▶ xcollector-bot ──HTTP──▶ xcollector-backend
                                  │                    （SQLite + 附件卷）
                                  │ 每日摘要推回 QQ
                                  ▼
浏览器 ──▶ 你的 web server ──┬── /      ──▶ dist/     （前端静态文件）
                              ├── /api/  ──▶ backend
                              └── /bot/  ──▶ bot
```

| 服务 | 作用 | 端口 |
|---|---|---|
| `backend` | 数据层：存储、查询、附件 | `127.0.0.1:8000` |
| `bot` | 接 OneBot、筛选、抽取、摘要、指令 | `127.0.0.1:8082`（HTTP）、`127.0.0.1:8081`（反向 WS） |
| 前端 | 静态文件，由你自己的 web server 托管 | 你决定 |
| NapCat | QQ 客户端，不在这份编排里，需自行安装登录 | 通常 `3001` |

**前端不产出镜像、也不带 nginx** —— 它只负责 `npm run build` 出 `dist/`，
由你自己的 web server 托管并加上两条反代。三者**必须同源**，否则浏览器会跨域。

## 技术栈

| | |
|---|---|
| 消息层 | Python 3.12 · FastAPI · websockets · OneBot v11（NapCat） |
| 数据层 | Python 3.12 · FastAPI · SQLite |
| 前端 | Vue 3 · Element Plus · Pinia · Vite |
| 大模型 | 自研网关，支持 OpenAI 格式与 Google 原生格式，无厂商 SDK |
| 部署 | Docker Compose · GitHub Container Registry |

## 设计原则

1. **召回优先，绝不静默丢弃。** 失败模式不是「总结得不好」，而是「该看到的没看到」。
   大模型是抽取器，不是裁判。
2. **原始消息最先落库。** QQ 不会重发，所以消息先存进后端，之后才下载附件、调模型。
   后面任何一步崩了都能重来。
3. **系统必须暴露自己的盲区。** 要能回答「今天有多少条被丢弃、丢在哪一步、
   哪些群断线了」，否则无法区分「今天没通知」和「系统瞎了」。
4. **bot 不保存需要跨重启存活的状态。** 待确认、编号映射、摘要发送记录全在后端，
   bot 容器随时可以删掉重建。

## 明确不做

- 实时推送（那是又一次打断）
- 微信个人号自动化（封的是个人主号）
- 水群 / 公众号 / 媒体的信息处理（信噪比太低，只处理官方通知）
- 全自动理解一切（人保留否决权）

## 快速开始

**前置**：NapCat 已安装并登录 QQ（见下面「接 NapCat」）。

```bash
git clone https://github.com/Xqy1y4ever/xcollector-deploy.git
cd xcollector-deploy
cp .env.example .env
```

至少要改这几项：

| 配置 | 说明 |
|---|---|
| `API_TOKEN` | 写入令牌。生成一个随机串，**只给 bot 用，不进浏览器** |
| `WEB_API_TOKEN` | 网页令牌。**另外生成一个不同的**，前端登录页输入这个 |
| `GROUP_WHITELIST` | 要处理的群，格式 `群号:名称,群号:名称` |
| `SENDER_WHITELIST` | 要处理的发送者，格式 `QQ号:名称` |
| `ONEBOT_MODE` / `ONEBOT_WS_URL` | 见下面「接 NapCat」 |

> **两个白名单都是 fail-closed 的：留空 = 一个消息都不处理。** bot 只处理同时满足
> 「群在 `GROUP_WHITELIST`」且「发送者在 `SENDER_WHITELIST`」的消息。
> 没配好时启动日志会警告「会忽略所有消息」。如果某个群里谁发的都该收，
> 把 `SENDER_WHITELIST_MODE` 设成 `off`（那是**显式**放开）。

```bash
# 生成两个令牌
python3 -c "import secrets;print(secrets.token_hex(32))"
```

然后：

```bash
sh preflight.sh          # 预检：令牌、端口、镜像，有问题会一次列完
docker compose pull
docker compose up -d
docker compose ps
```

`preflight.sh` 只读，不改任何东西、不拉镜像、不起容器。它会检查 `.env` 是否完整、
两个令牌是否配好且不同、宿主机端口有没有被占（并告诉你是谁占的）、镜像能否拉到。
退出码 0 表示可以启动。

最后把 `dist/` 交给 web server 并加上两条反代（见下一节），打开页面登录即可。

### 只想先跑通，不想装 NapCat

bot 的 `app/tools/feed_event.py` 可以喂一条假事件走完整流水线，不需要 NapCat，
也不消耗大模型调用（`--extractor rule`）。详见
[bot 仓库的自检一节](https://github.com/Xqy1y4ever/xcollector-bot#自检)。

## 托管 dist

### 拿到 dist

**方式一：Release 附件**（部署机上不需要装 Node）

```bash
curl -L https://github.com/Xqy1y4ever/xcollector-web/releases/latest/download/dist.tar.gz \
  | tar xz -C /var/www/xcollector
# → /var/www/xcollector/dist/
```

**方式二：GHCR 的纯文件镜像**（已经在用 Docker 的话）

```bash
docker pull ghcr.io/xqy1y4ever/xcollector-web:latest
docker create --name xcw ghcr.io/xqy1y4ever/xcollector-web:latest
docker cp xcw:/dist/. /var/www/xcollector/dist/
docker rm xcw
```

> 这个镜像是 `FROM scratch` 的**文件袋**，没有运行时也没有服务，**不能 `docker run`**。

**方式三：自己构建** —— `npm ci && npm run build`。

想固定版本就把 URL 里的 `latest` 换成 `v1.2.3` 那样的 tag。

### 托管它

产物是纯静态站点，关键是三条规则：

| 路径 | 动作 |
|---|---|
| `/` | 静态文件；找不到就回 `index.html`（SPA 路由） |
| `/api/` | 反代到 `127.0.0.1:8000`，**前缀保留** |
| `/bot/` | 反代到 `127.0.0.1:8082`，**前缀要摘掉** |

并且**原样转发**浏览器带的 `Authorization` 头。

#### nginx

```nginx
server {
    listen 80;
    server_name _;
    root /path/to/xcollector-web/dist;
    index index.html;
    client_max_body_size 8m;

    location /assets/ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        try_files $uri =404;
    }
    location / {
        try_files $uri $uri/ /index.html;      # SPA fallback
    }

    # 可选但推荐的第二层防线：浏览器连写请求都发不出去。
    # 正则 location 优先级更高，所以要先把前端真正要用的两个 POST 放行，
    # 否则「人工修正」和「标记已读」会 403。
    location ~ ^/api/notifications/[^/]+/(corrections|read)$ {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header Authorization $http_authorization;
    }

    location /api/ {
        limit_except GET { deny all; }          # 其余一律只读
        proxy_pass http://127.0.0.1:8000;       # 结尾不带 /，前缀保留
        proxy_set_header Host $host;
        proxy_set_header Authorization $http_authorization;
    }

    location /bot/ {
        proxy_pass http://127.0.0.1:8082/;      # 结尾带 /，前缀被摘掉
        proxy_set_header Host $host;
        proxy_set_header Authorization $http_authorization;
    }
}
```

#### Caddy

```caddy
:80 {
    root * /path/to/xcollector-web/dist
    encode gzip

    handle /api/* {
        reverse_proxy 127.0.0.1:8000
    }
    handle /bot/* {
        uri strip_prefix /bot
        reverse_proxy 127.0.0.1:8082
    }
    handle {
        try_files {path} /index.html
        file_server
    }
}
```

Caddy 默认就会转发 `Authorization` 头，不用额外配置。

### 只想本机 / 局域网看？

不想装 web server 也可以：在 `xcollector-web` 里跑 `npm run dev`，
它的开发代理已经内置了上面三条规则。配合 Tailscale 就能从手机访问。

## 接 NapCat

NapCat 不在这份编排里 —— 它要跑在有 QQ 客户端的地方（通常就是宿主机），
安装与登录由你自己完成。两种接法二选一：

### A. 正向 WS（推荐）

1. NapCat 里开一个 **WebSocket 服务**，端口 `3001`
2. `.env`：

   ```env
   ONEBOT_MODE=client
   ONEBOT_WS_URL=ws://host.docker.internal:3001
   ```

`host.docker.internal` 已经在 compose 里通过 `extra_hosts` 配好。NapCat 在别的
机器上就换成那台的 IP。

### B. 反向 WS

1. NapCat 里配 **反向 WebSocket**，URL 填 `ws://<宿主机IP>:8081/onebot/ws`
2. `.env`：`ONEBOT_MODE=server`

容器内的 8081 已发布到宿主机 `127.0.0.1:8081`。如果 NapCat 在**另一台机器**上，
要把 compose 里的 `127.0.0.1:8081:8081` 改成 `8081:8081`，否则那台机器连不进来。

### 上线前确认

**没有别的东西也在连同一个 NapCat。** 如果有旧版后端还在跑，同一个 QQ 账号的
消息会被两条链路各收一份、**重复入库**。正确顺序：停旧后端 → 起这套 → 起 bot。

## 配置

- **`xcollector-deploy/.env`** —— 跨服务与业务配置（令牌、白名单、抽取模式、
  每日摘要、指令、端口）。这份文件同时喂给 backend 和 bot，每个进程只读自己认识的键。
- **`docker-compose.yml` 的 `environment`** —— 容器内部的地址
  （`BACKEND_BASE_URL` 用服务名 `http://backend:8000`、监听地址用 `0.0.0.0`）。
  这些不要写进 `.env`，写了也会被覆盖。

全部配置项见 [`.env.example`](.env.example)。

宿主机侧的三个端口都能在 `.env` 里改（`BACKEND_HOST_PORT` / `BOT_HOST_PORT` /
`ONEBOT_HOST_PORT`）。容器之间走 compose 内网，不经过宿主机端口，
所以改了不影响容器间通信 —— 只要把反向代理指到新端口。

### 两个令牌

| 令牌 | 谁用 | 能做什么 |
|---|---|---|
| `API_TOKEN` | 只有 bot（在服务器上） | 全部：入库、改机器字段、删除、发 QQ 消息 |
| `WEB_API_TOKEN` | 前端登录页（浏览器里） | 只能读、提交人工修正、标记已读 |

网页令牌必须交给登录页，所以任何能打开网页的人都能拿到它。**两个令牌配成同一个值，
分级就完全失效** —— `preflight.sh` 会直接报错，启动日志也会警告。

即使正确配置了，它**仍然是一个共享密钥**而不是账号体系：所有拿同一个网页令牌登录
的人权限完全一样，没有审计、没法单独吊销某个人；而且**读权限本身也是信息**，
所有原始消息和附件都能被看到。所以：

- **不要把页面暴露到公网**，并且**上 HTTPS**（明文 HTTP 下令牌在网线上是裸的）
- 要对外提供服务，就在前面套一层真正的认证（带登录的反向代理 / VPN / Tailscale）

> 前端仓库里的 `VITE_API_TOKEN` 是「预置令牌」的降级路径，方便不用登录页的
> 开发 / CI 场景。**正常部署不要填** —— 一旦填了，令牌会明文躺在 `dist/assets/*.js` 里。

## 镜像

默认从 GHCR 拉，在 `.env` 里配：

```env
IMAGE_BACKEND=ghcr.io/xqy1y4ever/xcollector-backend
IMAGE_BOT=ghcr.io/xqy1y4ever/xcollector-bot
VERSION=latest          # 或固定成某个 tag
PULL_POLICY=missing     # missing=本地没有才拉；always=每次 up 都拉最新
```

> 镜像路径必须**全小写**。GHCR 不接受大写，哪怕 GitHub 用户名含大写字母
> （`Xqy1y4ever` 要写成 `xqy1y4ever`）。

两个源码仓库各带一份 CI 工作流，推到 GitHub 后自动构建推送：推 `main` 出
`latest` + `sha-<短哈希>`，打 `v1.2.3` 这样的 tag 出正式版本。

**首次推送后要去 Packages 页面设一下可见性。** 设成 private 的话部署机要先登录：

```bash
echo <你的PAT，至少带 read:packages> | docker login ghcr.io -u Xqy1y4ever --password-stdin
```

### 从源码构建（可选）

三个仓库放在同级目录时：

```bash
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

## 数据与备份

唯一不可再生的东西都在 `backend-data` 这个命名卷里（SQLite 库 + 附件）：

```bash
# 备份
docker run --rm -v xcollector_backend-data:/data -v "$PWD":/backup alpine \
  tar czf /backup/xcollector-$(date +%F).tar.gz -C /data .

# 恢复
docker run --rm -v xcollector_backend-data:/data -v "$PWD":/backup alpine \
  tar xzf /backup/xcollector-YYYY-MM-DD.tar.gz -C /data
```

`bot` 容器**没有卷**：它不保存任何需要跨重启存活的状态，容器随便删。

## 升级

```bash
docker compose pull
docker compose up -d
```

后端启动时会自动做数据库增量迁移，老库直接升上来，不会丢数据。

**固定版本更稳**：把 `.env` 里的 `VERSION` 从 `latest` 改成某个
`sha-xxxxxxx` 或 `v1.2.3`，配合 `PULL_POLICY=missing`，就不会哪次 `up`
被意外升级。回滚同理 —— 改回旧 tag 再 `up` 即可（数据在卷里，不受影响）。

## 排查

```bash
docker compose logs -f bot          # 每条消息一行日志
docker compose logs -f backend
docker compose exec backend python -m tests.check_config    # 配置自检
docker compose exec bot python -m app.tools.check_llm       # 模型配置能不能用（联网）
```

常见问题：

| 现象 | 原因与处理 |
|---|---|
| **改了 `.env` 但不生效**（日志里还是旧地址 / 旧配置） | 容器的环境变量在**创建那一刻**就固定了。`docker compose restart` 只是重启进程，**不会**重读 `.env`；compose 认为服务定义没变时 `up -d` 也不会重建。用 `docker compose up -d --force-recreate bot`。`sh preflight.sh` 会直接把「容器里实际拿到的值」和「`.env` 里写的值」对出来 |
| `up` 时报 `failed to bind host port ... address already in use` | 宿主机端口被占。`sh preflight.sh` 会告诉你占用者；或在 `.env` 里改 `BACKEND_HOST_PORT` / `BOT_HOST_PORT`，并同步改反向代理 |
| `pull` 报 `denied` / `manifest unknown` | GHCR 上的包是 private 而部署机没登录，或镜像名含大写 |
| 页面显示「bot 未运行或不可达」 | `docker compose logs bot`，多半是 `ONEBOT_WS_URL` 连不上 NapCat（不会让 bot 崩，只是收不到消息） |
| 日志里「已连接」之后**立刻**断开 | NapCat 的 WebSocket 服务器配了 Token，而 `ONEBOT_ACCESS_TOKEN` 没填或不一致。以 NapCat 自己的日志为准；也可把 token 写在 URL 上：`ws://host.docker.internal:3001/?access_token=<token>` |
| 页面能开但列表空、状态页说「后端不可达」 | backend 没起来，或 `API_TOKEN` 不一致 |
| 状态页报错但通知列表正常 | 反代没把 `/bot` 前缀摘掉（`/api` 不用摘，所以只有状态页坏） |
| 证据图片显示不出来 | `ATTACHMENT_URL_TTL` 被设成了 0，附件签名链接失效 |

## 安全默认值

- `COMMAND_WHITELIST` 默认**留空 = 谁都不能发指令**
- `API_TOKEN` 留空时后端不校验任何请求，启动时会警告 —— 只适合完全可信的本机
- backend / bot 只绑 `127.0.0.1`，暴露面只有你自己部署的反向代理
- 两个容器都带 `no-new-privileges`

## 许可

MIT
