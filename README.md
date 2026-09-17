# Xcollector 部署编排

用 Docker Compose 把 Xcollector 的**后端**和 **bot** 跑起来。这是整套系统的部署入口。

## 架构

```
浏览器 ──▶ 你的 web server ──┬── /      ──▶ dist/   ← 前端静态文件
                              ├── /api/  ──▶ backend ← 数据层（SQLite + 附件，挂在卷上）
                              └── /bot/  ──▶ bot     ← 处理消息，连 OneBot
                                                │
                                                ▼
                                        NapCat（宿主机，你自己装）
```

| 服务 | 作用 | 发布到 |
|---|---|---|
| `backend` | 数据层：存储、查询、附件 | `127.0.0.1:8000` |
| `bot` | 接 OneBot、筛选、抽取、每日摘要、私聊指令 | `127.0.0.1:8082`（HTTP）、`127.0.0.1:8081`（反向 WS） |

**前端不在这份编排里。** `xcollector-web` 只产出 `dist/` 静态文件，你需要自己用
web server 托管它，并把两个前缀反代到上面两个端口。三者**必须同源**
（同一个 host:port），否则浏览器会跨域。

宿主机侧的三个端口都能在 `.env` 里改（`BACKEND_HOST_PORT` / `BOT_HOST_PORT` /
`ONEBOT_HOST_PORT`）。容器之间走 compose 内网，不经过宿主机端口，
所以改了不影响容器间通信 —— 只要把反向代理指到新端口。

## 技术栈

| | |
|---|---|
| 编排 | Docker Compose（只拉镜像，不构建） |
| 镜像 | GitHub Container Registry（GHCR） |
| 数据 | 命名卷 `backend-data`（SQLite + 附件） |
| 前端 | 你自己选的 web server（nginx / Caddy / …） |

## 快速开始

**前置**：`dist/` 已构建好，NapCat 已安装并登录 QQ。

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
| `GROUP_WHITELIST` | 你的官方通知群号 |
| `ONEBOT_MODE` / `ONEBOT_WS_URL` | 见下面「接 NapCat」 |

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

`preflight.sh` 只读，不改任何东西、不拉镜像、不起容器。它会检查 .env 是否完整、
两个令牌是否配好且不同、宿主机端口有没有被占（并告诉你是谁占的）、镜像能否拉到。
退出码 0 表示可以启动。

最后把 `dist/` 交给 web server 并加上两条反代（见下一节），打开页面登录即可。

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

两个源码仓库和本仓库放在同级目录时：

```bash
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

## 配置

- **`xcollector-deploy/.env`** —— 跨服务与业务配置（令牌、白名单、抽取模式、
  每日摘要、指令、端口）。这份文件同时喂给 backend 和 bot，每个进程只读自己认识的键。
- **`docker-compose.yml` 的 `environment`** —— 容器内部的地址
  （`BACKEND_BASE_URL` 用服务名 `http://backend:8000`、监听地址用 `0.0.0.0`）。
  这些不要写进 `.env`，写了也会被覆盖。

全部配置项见 [`.env.example`](.env.example)。

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
| `up` 时报 `failed to bind host port ... address already in use` | 宿主机端口被占。`sh preflight.sh` 会告诉你占用者；或在 `.env` 里改 `BACKEND_HOST_PORT` / `BOT_HOST_PORT`，并同步改反向代理 |
| `pull` 报 `denied` / `manifest unknown` | GHCR 上的包是 private 而部署机没登录，或镜像名含大写 |
| 页面显示「bot 未运行或不可达」 | `docker compose logs bot`，多半是 `ONEBOT_WS_URL` 连不上 NapCat（不会让 bot 崩，只是收不到消息） |
| 页面能开但列表空、状态页说「后端不可达」 | backend 没起来，或 `API_TOKEN` 不一致 |
| 状态页报错但通知列表正常 | 反代没把 `/bot` 前缀摘掉（`/api` 不用摘，所以只有状态页坏） |
| 证据图片显示不出来 | `ATTACHMENT_URL_TTL` 被设成了 0，附件签名链接失效 |

## 安全默认值

- `COMMAND_WHITELIST` 默认**留空 = 谁都不能发指令**
- `API_TOKEN` 留空时后端不校验任何请求，启动时会警告 —— 只适合完全可信的本机
- backend / bot 只绑 `127.0.0.1`，暴露面只有你自己部署的反向代理
- 两个容器都带 `no-new-privileges`
