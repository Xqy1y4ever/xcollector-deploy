#!/usr/bin/env sh
# 起 backend（栈 1）。
#
#     cp .env.example .env      # 第一次
#     ./start.sh
#
# 它做四件事，都是幂等的：
#   1. 建 Docker 网络（两个栈共用；bot 那边直接用这个名字）
#   2. 建数据卷（SQLite 库 + 附件都在里面）
#   3. 起容器
#   4. 等健康检查通过（最多 90 秒），然后打印下一步该干什么
#
# 不用 compose：一个容器 + 一个卷 + 一张网络，本来就是 `docker run` 一句话的事。
# 想手动跑，等价命令见 README「不用脚本的话」。

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 2
cd "$SCRIPT_DIR" || exit 2

# 从 .env 读一个键；读不到就用默认值。
# 刻意不 `source .env`：那会执行文件里的内容，而 .env 是可以被随便改的。
env_get() {
  _key=$1; _def=$2
  if [ -f .env ]; then
    _v=$(grep -E "^[[:space:]]*${_key}=" .env 2>/dev/null | tail -n 1 | sed -e "s/^[^=]*=//" -e 's/[[:space:]]*$//')
    if [ -n "${_v:-}" ]; then printf '%s' "$_v"; return; fi
  fi
  printf '%s' "$_def"
}

if [ ! -f .env ]; then
  echo "没有 .env —— 先复制一份： cp .env.example .env" >&2
  exit 2
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "没有 docker —— 先装 Docker Engine： https://docs.docker.com/engine/install/" >&2
  exit 2
fi
if ! docker info >/dev/null 2>&1; then
  echo "连不上 docker daemon（服务没起，或当前用户不在 docker 组）" >&2
  exit 2
fi

IMAGE=$(env_get IMAGE_BACKEND 'ghcr.io/xqy1y4ever/xcollector-backend')
VERSION=$(env_get VERSION 'latest')
PULL_POLICY=$(env_get PULL_POLICY 'always')
BIND=$(env_get BACKEND_BIND '127.0.0.1')
PORT=$(env_get BACKEND_HOST_PORT '8000')
VOLUME=$(env_get BACKEND_VOLUME 'xcollector_backend-data')
NETWORK=$(env_get XCOLLECTOR_NETWORK 'xcollector')
NAME=xcollector-backend
FULL_IMAGE="$IMAGE:$VERSION"

# ---- 1. 网络（两个栈共用；bot 的 start.sh 只检查、不建）----
if docker network inspect "$NETWORK" >/dev/null 2>&1; then
  echo "网络 $NETWORK 已存在"
else
  docker network create "$NETWORK" >/dev/null
  echo "建好网络 $NETWORK"
fi

# ---- 2. 数据卷 ----
if docker volume inspect "$VOLUME" >/dev/null 2>&1; then
  echo "数据卷 $VOLUME 已存在（数据在里面，别删）"
else
  docker volume create "$VOLUME" >/dev/null
  echo "建好数据卷 $VOLUME"
fi

# ---- 3. 容器 ----
if [ "$PULL_POLICY" = "always" ]; then
  echo "拉取镜像 $FULL_IMAGE …"
  docker pull "$FULL_IMAGE" >/dev/null || echo "  拉取失败（用本地已有的镜像继续）"
fi

# 同名容器先删掉再起：所有状态都在卷里，删容器不会丢数据。
if docker container inspect "$NAME" >/dev/null 2>&1; then
  echo "已存在同名容器 $NAME —— 先删掉再起（数据在卷 $VOLUME 里，不会丢）"
  docker rm -f "$NAME" >/dev/null
fi

echo "启动 $NAME （$FULL_IMAGE）…"
docker run -d \
  --name "$NAME" \
  --restart unless-stopped \
  --network "$NETWORK" \
  --network-alias backend \
  --env-file .env \
  -e DB_PATH=data/xcollector.db \
  -e ATTACHMENT_DIR=data/attachments \
  -e SERVER_HOST=0.0.0.0 \
  -e SERVER_PORT=8000 \
  -p "${BIND}:${PORT}:8000" \
  -v "${VOLUME}:/app/data" \
  --security-opt no-new-privileges:true \
  "$FULL_IMAGE" >/dev/null
# --network-alias backend：让别的容器能用 `http://backend:8000` 找到本服务。
#
# 这一条是**必须的**，因为 `docker run` 和 compose 不一样：compose 会自动把
# **服务名**注册成网络别名，而 `docker run` 只注册**容器名**（xcollector-backend）。
# 少了它，bot 里那句 BACKEND_BASE_URL=http://backend:8000 会解析失败，
# 报 `[Errno -2] Name or service not known`（表现是「指令报错、状态页后端不可达」）。
# 两个名字都注册着，所以你写 backend 或者 xcollector-backend 都能通。

# ---- 4. 等健康检查 ----
# 镜像自带 HEALTHCHECK（带 API_TOKEN 探 /api/health），所以这里不用 curl。
echo -n "等它变健康"
i=0
while [ "$i" -lt 45 ]; do
  STATUS=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$NAME" 2>/dev/null || echo missing)
  case "$STATUS" in
    healthy) echo " … 好了"; break ;;
    unhealthy) echo ""; echo "容器报告 unhealthy，看日志： docker logs $NAME" >&2; exit 1 ;;
  esac
  echo -n "."
  i=$((i + 1))
  sleep 2
done
if [ "$STATUS" != "healthy" ]; then
  echo ""
  echo "90 秒内没变健康（当前状态：$STATUS）。看日志： docker logs $NAME" >&2
  exit 1
fi

echo
echo "backend 起来了："
echo "  接口      http://127.0.0.1:${PORT}"
echo "  数据卷    $VOLUME（SQLite 库 + 附件）"
echo "  反代      /api/ → http://127.0.0.1:${PORT} （前缀保留、原样转发 Authorization）"
echo
echo "接着起 bot（另一个栈，自己的 .env）："
echo "  cd ../bot"
echo "  cp .env.example .env      # API_TOKEN 填和这边同一个值"
echo "  ./start.sh"
echo
echo "常用："
echo "  docker logs -f $NAME        # 看日志"
echo "  ./stop.sh                   # 停（数据留着）"
