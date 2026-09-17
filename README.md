# Xcollector 部署编排

用 Docker Compose 把**后端和 bot** 组织起来。

```
浏览器 ──▶ 你的 web server ──┬── /      ──▶ dist/   ← 前端构建产物，静态文件
                              ├── /api/  ──▶ backend ← 纯数据层，SQLite + 附件（挂在卷上）
                              └── /bot/  ──▶ bot     ← 处理消息，连 OneBot
                                                │
                                                ▼
                                        NapCat（宿主机，你自己装）
```

**前端不在这份编排里。** `xcollector-web` 只负责产出 `dist/`，不带容器、不带 nginx。
你需要自己用一个 web server 托管静态文件，并把两个前缀反代到下面两个端口 ——
三者**必须同源**（同一个 host:port），否则浏览器会跨域。

| 服务 | 作用 | 发布到 |
|---|---|---|
| `backend` | 纯数据层。所有增删查改、附件存取 | `127.0.0.1:8000` |
| `bot` | 处理消息：接 OneBot、筛选、抽取、digest、私聊指令 | `127.0.0.1:8082`（HTTP API）、`127.0.0.1:8081`（反向 WS） |

> 这两个端口以前是不对外开的（由同网络的 nginx 走内部访问）。**现在必须发布**，
> 因为你的 web server 要靠它们反代。

宿主机侧这三个端口都能在 `.env` 里改（`BACKEND_HOST_PORT` / `BOT_HOST_PORT` /
`ONEBOT_HOST_PORT`）。容器之间走 compose 内网（bot 用的是 `http://backend:8000`），
**不经过宿主机端口**，所以改了不影响任何容器间通信 —— 只要把反向代理指到新端口。

端口被占是部署时最常见的事故，报错长这样：

```
Error response from daemon: driver failed programming external connectivity ...
failed to bind host port for 127.0.0.1:8000:...: address already in use
```

先查是谁占的，再决定是「停掉它」还是「换个端口」：

```bash
ss -ltnp | grep ':8000'                                  # 看占用进程（要 root）
docker ps --format '{{.Names}}\t{{.Ports}}' | grep 8000   # 是不是别的容器
docker compose ls -a                                      # 有没有遗留的旧项目
```

## 快速开始

**前置**：两个镜像要先在 GHCR 上存在（见下一节）；`dist/` 要先构建好。

```bash
# 1) 起后端和 bot
cd xcollector-deploy
cp .env.example .env
# 至少改这几项：
#   API_TOKEN=<生成一个>
#   GROUP_WHITELIST=<你的官方通知群号>
#   ONEBOT_WS_URL / ONEBOT_MODE=<按下面的 NapCat 说明>

docker compose pull
docker compose up -d
docker compose ps

# 2) 构建前端并托管 dist/
cd ../xcollector-web
npm ci && npm run build          # 产出 dist/
```

然后把 `dist/` 交给你的 web server，按下一节的配置加上两条反代。
打开页面后用 `.env` 里的 `API_TOKEN` 登录。

**先用 `EXTRACTOR=rule` 跑通，再接 LLM。**

## 托管 dist

### 先拿到 dist（不用装 Node）

`xcollector-web` 的 CI 会构建好并发布成 Release 附件，部署机上直接下载：

```bash
sudo mkdir -p /var/www/xcollector
curl -L https://github.com/Xqy1y4ever/xcollector-web/releases/latest/download/dist.tar.gz \
  | sudo tar xz -C /var/www/xcollector
# → /var/www/xcollector/dist/
```

已经在用 Docker 的话，也可以从 GHCR 取（同一个产物）：

```bash
docker pull ghcr.io/xqy1y4ever/xcollector-web:latest
docker create --name xcw ghcr.io/xqy1y4ever/xcollector-web:latest
docker cp xcw:/dist/. /var/www/xcollector/dist/
docker rm xcw
```

> GHCR 上那个镜像是 `FROM scratch` 的**纯文件袋**，没有运行时也没有服务，
> **不能 `docker run`** —— 它只是让你少装一个 Node。

想跟着某个固定版本走，把 URL 里的 `latest` 换成 `v1.2.3` 那样的 tag
（`releases/latest/` 要改成 `releases/download/v1.2.3/`）。

也可以自己构建：`npm ci && npm run build`。

### 然后托管它

产物是**纯静态站点**。用哪个 web server 都行，关键是三条规则：

| 路径 | 动作 |
|---|---|
| `/` | 静态文件；找不到就回 `index.html`（SPA 路由） |
| `/api/` | 反代到 `127.0.0.1:8000`，**前缀保留** |
| `/bot/` | 反代到 `127.0.0.1:8082`，**前缀要摘掉** |

（这两个端口是默认值。若你在 `.env` 里改过 `BACKEND_HOST_PORT` / `BOT_HOST_PORT`，
下面的 `proxy_pass` / `reverse_proxy` 也要跟着改。）

并且**原样转发**浏览器带的 `Authorization` 头 —— 认证在前端登录页做，
代理里一旦无条件注入服务端 token，登录页就形同虚设。

### nginx

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

    location /api/ {
        proxy_pass http://127.0.0.1:8000;      # 结尾不带 /，前缀保留
        proxy_set_header Host $host;
        proxy_set_header Authorization $http_authorization;
    }

    location /bot/ {
        proxy_pass http://127.0.0.1:8082/;     # 结尾带 /，前缀被摘掉
        proxy_set_header Host $host;
        proxy_set_header Authorization $http_authorization;
    }
}
```

### Caddy

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

> Caddy 默认就会转发 `Authorization` 头，不用额外配置。

### 只想本机/局域网看？

不想装 web server 也可以：在 `xcollector-web` 里跑 `npm run dev`，
它的 dev 代理已经内置了上面三条规则。配合 Tailscale 就能从手机访问。

## 镜像从哪来

默认从 GitHub Container Registry 拉，在 `.env` 里配：

```env
IMAGE_BACKEND=ghcr.io/xqy1y4ever/xcollector-backend
IMAGE_BOT=ghcr.io/xqy1y4ever/xcollector-bot
VERSION=latest          # 或固定成 CI 推上来的某个 tag
PULL_POLICY=missing     # missing=本地没有才拉；always=每次 up 都拉最新
```

> ⚠ **镜像路径必须全小写。** GHCR 不接受大写，哪怕 GitHub 用户名含大写字母：
> `Xqy1y4ever` 必须写成 `xqy1y4ever`，否则会报
> `repository name must be lowercase`。两个仓库里的 CI 已经显式做了小写化。

### 发布镜像

**后端与 bot** 两个仓库各带一份 `.github/workflows/docker.yml`，推到 GitHub 后自动构建推送：

| 触发 | 推的 tag |
|---|---|
| 推到 `main` | `latest` + `sha-<短哈希>` |
| 推到其它分支 | 分支名 |
| 打 `v1.2.3` 这样的 tag | `1.2.3` / `1.2` / `latest` |
| 手动 `workflow_dispatch` | 同上 |

**首次推送后要去 GitHub 的 Packages 页面把两个包的可见性设一下。**
设成 private 的话，部署机上要先登录：

```bash
echo <你的PAT，至少带 read:packages> | docker login ghcr.io -u Xqy1y4ever --password-stdin
```

> `xcollector-web` **没有** CI 工作流 —— 它不产出镜像。前端的分发方式就是
> `npm ci && npm run build` 出来的 `dist/` 目录。

### 从源码构建（可选）

两个源码仓库和 `xcollector-deploy` 放在**同级目录**时：

```bash
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

叠加文件只补 `build:`，镜像名沿用主文件的，两种模式随时可切。

## 配置放在哪

- **`xcollector-deploy/.env`** —— 跨服务与业务配置（白名单、抽取模式、digest、
  指令、token）。这份文件同时喂给 backend 和 bot，每个进程只读自己认识的键。
- **`docker-compose.yml` 的 `environment`** —— 容器内部的地址（`BACKEND_BASE_URL`
  用服务名 `http://backend:8000`、监听地址用 `0.0.0.0`）。这些**不要**写进 `.env`，
  写了也会被覆盖。

## NapCat 怎么接

NapCat 不在这份编排里 —— 它要跑在有 QQ 客户端的地方（通常就是宿主机），
安装与登录由你自己完成。两种接法二选一：

### A. 正向 WS（推荐）

1. 在 NapCat 里开一个 **WebSocket 服务**，端口 `3001`
2. `.env`：
   ```env
   ONEBOT_MODE=client
   ONEBOT_WS_URL=ws://host.docker.internal:3001
   ```

`host.docker.internal` 在 compose 里已经通过 `extra_hosts` 配好（Linux 需要，
Docker Desktop 自带）。NapCat 在别的机器上就换成那台的 IP。

### B. 反向 WS

1. 在 NapCat 里配 **反向 WebSocket**，URL 填 `ws://<宿主机IP>:8081/onebot/ws`
2. `.env`：
   ```env
   ONEBOT_MODE=server
   ```

容器内的 8081 已发布到宿主机 `127.0.0.1:8081`。如果 NapCat 在**另一台机器**上，
要把 compose 里的 `127.0.0.1:8081:8081` 改成 `8081:8081`，否则那台机器连不进来。

### ⚠ 上线前必须确认

**没有别的东西也在连同一个 NapCat。** 拆分重构之前的旧版后端会自己去连 OneBot，
如果它还在跑，同一个 QQ 账号的消息会被两条链路各收一份、**重复入库**。
正确顺序：停旧后端 → 起这套 → 起 bot。

## 关于 API_TOKEN

契约里整套系统只有**一个**共享密钥：bot 递出、后端校验。前端在登录页让你输入它。

**认证做在哪一层，效果完全不同：**

| 做法 | 代理里怎么写 | 效果 |
|---|---|---|
| **前端登录（默认）** | `proxy_set_header Authorization $http_authorization;` | 浏览器带上用户输入（存在 storage 里）的 token。**不进 JS bundle**，也不是"谁都能进"。 |
| 服务端注入 | `proxy_set_header Authorization "Bearer <token>";` | 谁都能进 —— 不带 Authorization 的请求也会被补上正确的 token。**前端登录形同虚设**。只在完全可信的内网、图省事时用。 |

默认是前者。要换成后者，改你自己 web server 的配置即可（**不是**改这个仓库 ——
这里已经没有 nginx 层了）。

### 前端登录能力的边界（别高估它）

- 它是**一个共享密钥**，不是按用户的账号体系 —— 所有登录的人权限完全一样，
  没有审计、没有分级
- token 存在浏览器 storage 里，**任何能在这台浏览器上执行 JS 的东西都能读到**，
  XSS 会泄露它
- 所以：**真正的边界仍然是不要把页面暴露到公网**。要对外提供服务，就在前面套
  一层真正的认证（带登录的反向代理 / VPN / Tailscale 之类的私有网络）

> 前端仓库里也有 `VITE_API_TOKEN`，那是「预置令牌」的降级路径：环境变量有值而
> 登录态为空时直接用它，方便不用登录页的开发/CI 场景。**正常部署不要填** ——
> 一旦填了，token 会明文躺在 `dist/assets/*.js` 里。

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

`bot` 容器**没有卷**，这是刻意的：它不持有任何需要跨重启存活的状态
（待确认、`/list` 编号映射、digest 发送记录全在后端）。容器随便删。

## 升级

```bash
cd xcollector-deploy
docker compose pull
docker compose up -d
```

后端启动时会自动跑 `ALTER TABLE` 增量迁移，老库直接升上来，不会丢数据
（`db.py` 的 `_MIGRATIONS`）。

**固定版本更稳**：把 `.env` 里的 `VERSION` 从 `latest` 改成某个 `sha-xxxxxxx`
或 `v1.2.3`，再配合 `PULL_POLICY=missing`，就不会哪次 `up` 被意外升级。
回滚同理 —— 改回旧 tag，`docker compose up -d` 即可（数据在卷里，不受影响）。

> `EXTRACTOR=llm` 开箱可用，**镜像里不需要任何额外的 LLM 依赖**：
> 多厂商调用走 bot 自带的 `app/llm/` 网关（OpenAI 格式 + Google 原生格式），
> 只用到 `httpx`。所以没有 `BUILD_LLM` 这个构建开关了。

## 排查

```bash
docker compose logs -f bot          # 每条消息一行日志都在这里
docker compose logs -f backend
docker compose exec backend python -m tests.check_config       # 配置边界自检
docker compose exec bot python -m tests.check_timeparse        # 时间解析回归
docker compose exec bot python -m tests.check_location         # 地点抽取回归
docker compose exec bot python -m app.tools.check_llm          # 模型配置能不能用（要联网）
```

**`up` 时报 `failed to bind host port ... address already in use`** → 宿主机那个端口
被占了，不是配置写错。查占用者并决定停掉它还是换端口：

```bash
ss -ltnp | grep ':8000'
docker ps --format '{{.Names}}\t{{.Ports}}' | grep 8000
```

换端口：在 `.env` 里改 `BACKEND_HOST_PORT`（或 `BOT_HOST_PORT`），
然后同步改反向代理，再 `docker compose down && docker compose up -d`。
如果是以前遗留的 xcollector 容器占着，先 `docker compose down` 清掉。

浏览器打开页面看到「bot 未运行或不可达」→ 看 `docker compose logs bot`，
多半是 `ONEBOT_WS_URL` 连不上 NapCat（这不会让 bot 崩，只会让它收不到消息）。

页面能开但列表空、且状态页说「后端不可达」→ backend 没起来或 `API_TOKEN` 不一致。

## 安全默认值

- `COMMAND_WHITELIST` 默认**留空 = 谁都不能发指令**（不是"谁都能"）
- `API_TOKEN` 留空时后端不校验，README 和启动日志都会警告 —— 只适合完全可信的本机
- backend / bot 只绑 `127.0.0.1`（**前端产物和反代由你自己部署，那才是暴露面**）
- 两个容器都带 `no-new-privileges`
- `.dockerignore` 排除了 `data/`，真实库和附件不会被烤进镜像

## 验证状态（如实说明）

这套编排是在**没有安装 Docker 的机器上**写的，因此：

- ✅ YAML 语法、锚点解析、端口变量替换、镜像名大小写、构建上下文与 CI 小写化都经过静态检查
- ✅ 两个容器里跑的命令与配置项，都是本机原生跑通过的（后端 179 条接口断言、
  bot 136 条端到端断言 + 96 条 LLM 网关断言、前端 `npm run build` 通过）
- ✅ **两个镜像确实已经构建并推上 GHCR 了** —— CI 成功，匿名拉 manifest 能取到
  （bot 镜像压缩层合计 57 MB）
- ❌ **没有真正 `docker compose up` 或 `docker compose pull` 跑过** ——
  容器网络是否如预期，需要在有 Docker 的机器上确认
- ❌ **README 里那两份 nginx / Caddy 配置没有实跑过** —— 语法是照标准写的，
  但没在真实 web server 上验证过

第一次跑如果出问题，按这个顺序排查：

1. **GHCR 上有没有镜像** —— Packages 页面能看到两个包吗？private 的话部署机
   登录了吗？（`docker compose pull` 会直接报 `denied` 或 `manifest unknown`）
2. **CI 有没有跑成功** —— 仓库的 Actions 页签。失败最常见的原因是镜像名带大写。
3. **宿主机端口被占** —— `failed to bind host port ... address already in use`。
   改 `.env` 里的 `BACKEND_HOST_PORT` / `BOT_HOST_PORT` 即可（见上面「快速开始」）。
4. **你的反代有没有把 `/bot` 前缀摘掉** —— 这是最容易写错的一处。
   反代配错的表现是状态页报错、而通知列表正常（因为 `/api` 不用摘前缀）。
5. **`bot` 能不能解析 `host.docker.internal`** —— `docker compose logs bot`，
   连不上 NapCat 不会让 bot 崩，只会让它收不到消息。
