# Xcollector 部署编排

用 Docker Compose 把三个服务组织起来。**只需要一个对外端口**（默认 8080）。

```
浏览器 ──▶ web (nginx) ──┬── /api/  ──▶ backend   ← 纯数据层，SQLite + 附件（挂在卷上）
                          └── /bot/  ──▶ bot       ← 处理消息，连 OneBot
                                            │
                                            ▼
                                    NapCat（宿主机，你自己装）
```

| 服务 | 作用 | 对外端口 |
|---|---|---|
| `web` | 静态站点 + 反向代理，并在这个位置**注入 Authorization 头** | `${WEB_PORT:-8080}` |
| `backend` | 纯数据层。所有增删查改、附件存取 | 仅 `127.0.0.1:8000`（调试用） |
| `bot` | 处理消息：接 OneBot、筛选、抽取、digest、私聊指令 | 仅 `127.0.0.1:8081`（反向 WS 用） |

`bot` 的 HTTP API（8082）**不对外开** —— 只有 web 的 nginx 需要访问它，走内部网络。

## 快速开始

```bash
cd xcollector-deploy
cp .env.example .env
# 至少改这三项：
#   API_TOKEN=<生成一个>
#   GROUP_WHITELIST=<你的官方通知群号>
#   ONEBOT_WS_URL / ONEBOT_MODE=<按下面的 NapCat 说明>

docker compose up -d --build
docker compose ps
```

打开 `http://<主机>:8080`。

**先用 `EXTRACTOR=rule` 跑通，再接 LLM。** 规则模式不需要 API key、不需要 litellm，
能验证整条链路（收发、存储、展示）是否通了。通了之后再改 `EXTRACTOR=llm`、
`BUILD_LLM=1` 重新构建。

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

契约里整套系统只有**一个**共享密钥：bot 递出、后端校验。

Docker 部署下它**不进前端 bundle**：`nginx.conf.template` 在代理 `/api/` 和 `/bot/`
时把 `Authorization` 头注入进去，token 只存在于 nginx 容器的环境变量里。
这比把 token 打进 JS 里安全得多 —— 后者任何能打开页面的人都能读到。

**但它仍然不是完整的鉴权边界**：任何能访问 `http://<主机>:8080` 的人，都能通过
nginx 访问你的任务数据。真正的边界是**不要把这个端口暴露到公网**。要对外提供服务，
就在前面再套一层带认证的反向代理（或者用 VPN / Tailscale 之类的私有网络）。

> 前端仓库里也有 `VITE_API_TOKEN`，那是给「不用 Docker、直接 `npm run dev` / 自己
> 部署静态文件」的场景用的。Dockerfile 里刻意把它留空。

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
docker compose build            # 或 build --pull 拉新基础镜像
docker compose up -d
```

后端启动时会自动跑 `ALTER TABLE` 增量迁移，老库直接升上来，不会丢数据
（`db.py` 的 `_MIGRATIONS`）。

## 排查

```bash
docker compose logs -f bot          # 每条消息一行日志都在这里
docker compose logs -f backend
docker compose exec backend python -m tests.check_config       # 配置边界自检
docker compose exec bot python -m tests.check_timeparse        # 时间解析回归
docker compose exec bot python -m tests.check_location         # 地点抽取回归
```

浏览器打开页面看到「bot 未运行或不可达」→ 看 `docker compose logs bot`，
多半是 `ONEBOT_WS_URL` 连不上 NapCat（这不会让 bot 崩，只会让它收不到消息）。

页面能开但列表空、且状态页说「后端不可达」→ backend 没起来或 `API_TOKEN` 不一致。

## 安全默认值

- `COMMAND_WHITELIST` 默认**留空 = 谁都不能发指令**（不是"谁都能"）
- `API_TOKEN` 留空时后端不校验，README 和启动日志都会警告 —— 只适合完全可信的本机
- backend / bot 只绑 `127.0.0.1`
- 三个容器都带 `no-new-privileges`
- `.dockerignore` 排除了 `data/`，真实库和附件不会被烤进镜像

## 验证状态（如实说明）

这套编排是在**没有安装 Docker 的机器上**写的，因此：

- ✅ YAML 语法、路径引用、端口与网络拓扑都经过检查
- ✅ 三个容器里跑的命令与配置项，都是本机原生跑通过的（后端 179 条接口断言、
  bot 136 条端到端断言、前端 `npm run build` 通过）
- ❌ **没有真正 `docker compose up` 跑过一次** —— 镜像能不能构建、容器网络是否如
  预期，都需要你在有 Docker 的机器上确认

第一次跑如果出问题，优先看这三处：
`docker compose build` 阶段的依赖安装、`web` 容器里 nginx 是否成功渲染模板
（`docker compose logs web` 里会有 envsubst 的报错）、`bot` 能否解析
`host.docker.internal`。
