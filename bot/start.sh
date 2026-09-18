#!/usr/bin/env sh
# 起 bot（栈 2）。
#
#     cp .env.example .env      # 第一次
#     ./start.sh                # 起 bot
#     ./start.sh client         # 起离线客户端（可选，与 bot 的入库二选一）
#
# 前提：**先起 backend**（../backend/start.sh）。它建的那张 Docker 网络
# （默认叫 xcollector）是 bot 找到后端的方式：BACKEND_BASE_URL 里的主机名要能在
# 那张网络里解析 —— 默认写的是容器名 xcollector-backend。
# 后端没起来时 bot 不会崩，只是头几秒的调用会失败、稍后自己接上。
#
# 不用 compose：两个容器各一条 `docker run`。想手动跑，等价命令见 README。

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 2
cd "$SCRIPT_DIR" || exit 2

env_get() {
  _key=$1; _def=$2
  if [ -f .env ]; then
    _v=$(grep -E "^[[:space:]]*${_key}=" .env 2>/dev/null | tail -n 1 | sed -e "s/^[^=]*=//" -e 's/[[:space:]]*$//')
    if [ -n "${_v:-}" ]; then printf '%s' "$_v"; return; fi
  fi
  printf '%s' "$_def"
}

usage() {
  echo "用法： ./start.sh [bot|client]" >&2
  echo "" >&2
  echo "  bot     （默认）实时链路：连 NapCat，处理群消息" >&2
  echo "  client  离线链路：读聊天记录库入库，不连 QQ —— 与 bot 二选一" >&2
  exit 2
}

TARGET=${1:-bot}
case "$TARGET" in
  bot|client) ;;
  -h|--help) usage ;;
  *) usage ;;
esac

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

VERSION=$(env_get VERSION 'latest')
PULL_POLICY=$(env_get PULL_POLICY 'always')
BIND=$(env_get BOT_BIND '127.0.0.1')
NETWORK=$(env_get XCOLLECTOR_NETWORK 'xcollector')
# 默认用**容器名**：`docker run` 一定会把容器名注册成网络名，而 compose 的服务名
# 别名（backend）不会自动有。backend 的 start.sh 现在两个名字都注册，所以写哪个都行；
# 但默认用容器名更保险（旧容器、或以后换成别的编排方式都不会踩到）。
BACKEND_URL=$(env_get BACKEND_BASE_URL 'http://xcollector-backend:8000')

# ---- 那条网络必须已经存在（由 backend 的 start.sh 建）----
if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
  echo "找不到 Docker 网络 $NETWORK —— bot 靠它访问后端。" >&2
  echo "先起 backend（在另一个目录里）：" >&2
  echo "    cd ../backend && ./start.sh" >&2
  exit 2
fi

# ---- 起 bot ----
if [ "$TARGET" = "bot" ]; then
  IMAGE=$(env_get IMAGE_BOT 'ghcr.io/xqy1y4ever/xcollector-bot')
  NAME=xcollector-bot
  BOT_PORT=$(env_get BOT_HOST_PORT '8082')
  ONEBOT_PORT=$(env_get ONEBOT_HOST_PORT '8081')
  FULL_IMAGE="$IMAGE:$VERSION"

  if [ "$PULL_POLICY" = "always" ]; then
    echo "拉取镜像 $FULL_IMAGE …"
    docker pull "$FULL_IMAGE" >/dev/null || echo "  拉取失败（用本地已有的镜像继续）"
  fi

  # 同名容器先删掉再起。bot 不保存跨重启状态（待确认、编号映射都在后端），
  # 所以删容器不会丢任何待办。
  if docker container inspect "$NAME" >/dev/null 2>&1; then
    echo "已存在同名容器 $NAME —— 先删掉再起（bot 没有需要保留的本地状态）"
    docker rm -f "$NAME" >/dev/null
  fi

  echo "启动 $NAME （$FULL_IMAGE）…"
  docker run -d \
    --name "$NAME" \
    --restart unless-stopped \
    --network "$NETWORK" \
    --env-file .env \
    -e BACKEND_BASE_URL="$BACKEND_URL" \
    -e BOT_LISTEN_HOST=0.0.0.0 \
    -e BOT_LISTEN_PORT=8082 \
    -e ONEBOT_LISTEN_HOST=0.0.0.0 \
    -p "${BIND}:${BOT_PORT}:8082" \
    -p "${BIND}:${ONEBOT_PORT}:8081" \
    --add-host host.docker.internal:host-gateway \
    --security-opt no-new-privileges:true \
    "$FULL_IMAGE" >/dev/null


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

  if [ -z "$(env_get GROUP_WHITELIST '')" ] || [ -z "$(env_get SENDER_WHITELIST '')" ]; then
    echo
    echo "⚠️ 白名单里有空的 —— 白名单是 fail-closed 的：**留空 = 一个消息都不处理**。"
    echo "   填好 GROUP_WHITELIST / SENDER_WHITELIST，然后 ./start.sh 重起一次。"
  fi

  ONEBOT_MODE_V=$(env_get ONEBOT_MODE 'client')
  echo
  echo "bot 起来了："
  echo "  管理接口  http://127.0.0.1:${BOT_PORT}/api/status   （要 Bearer 管理令牌）"
  if [ "$ONEBOT_MODE_V" = "server" ]; then
    echo "  OneBot    server 模式：NapCat 反向连 ws://<本机>:${ONEBOT_PORT}$(env_get ONEBOT_LISTEN_PATH '/onebot/ws')"
  else
    echo "  OneBot    client 模式：连 $(env_get ONEBOT_WS_URL 'ws://host.docker.internal:3001')"
  fi
  echo
  echo "  连不上 NapCat 不会让容器退出，只是收不到消息："
  echo "    docker logs -f $NAME      # 看「已连接」/断线原因"
  echo "    ./stop.sh                 # 停（bot 没有需要保留的本地状态）"
  echo
  echo "第一次用要先注册：在 QQ 里给机器人发 /注册 拿验证码，再到网页上完成注册。"
  exit 0
fi

# ---- 起离线客户端 ----
IMAGE=$(env_get IMAGE_CLIENT 'ghcr.io/xqy1y4ever/xcollector-client')
NAME=xcollector-client
FULL_IMAGE="$IMAGE:$VERSION"
HOST_DIR=$(env_get CLIENT_NT_MSG_HOST_DIR '')
TOKEN=$(env_get CLIENT_TOKEN '')

if [ -z "$HOST_DIR" ]; then
  echo "没有配 CLIENT_NT_MSG_HOST_DIR —— 它要指向放着 nt_msg.db（或 nt_msg_export.db）的目录" >&2
  exit 2
fi
if [ ! -d "$HOST_DIR" ]; then
  echo "CLIENT_NT_MSG_HOST_DIR 不是目录或不存在：$HOST_DIR" >&2
  exit 2
fi
if [ -z "$TOKEN" ]; then
  echo "没有配 CLIENT_TOKEN —— 客户端要用**某个用户的 UserToken**（xc_ 开头）写后端" >&2
  exit 2
fi

if [ "$PULL_POLICY" = "always" ]; then
  echo "拉取镜像 $FULL_IMAGE …"
  docker pull "$FULL_IMAGE" >/dev/null || echo "  拉取失败（用本地已有的镜像）"
fi

if docker container inspect "$NAME" >/dev/null 2>&1; then
  echo "已存在同名容器 $NAME —— 先删掉再起"
  docker rm -f "$NAME" >/dev/null
fi

# 状态库（镜像）默认放在源库旁边，也在那个挂载目录里，所以重建容器不会丢。
# 用 `set --` 攒参数而不是拼一个字符串：路径里带空格时拼接会散架。
ATTACH_HOST=$(env_get CLIENT_ATTACHMENT_HOST_PATH '')

echo "启动 $NAME （$FULL_IMAGE）…"
set -- --name "$NAME" \
  --restart unless-stopped \
  --network "$NETWORK" \
  --env-file .env \
  -e BACKEND_BASE_URL="$BACKEND_URL" \
  -v "${HOST_DIR}:/data/nt:rw"
if [ -n "$ATTACH_HOST" ]; then
  set -- "$@" \
    -v "${ATTACH_HOST}:/data/attachments:ro" \
    -e CLIENT_ATTACHMENT_ROOT=/data/attachments
fi
set -- "$@" --security-opt no-new-privileges:true "$FULL_IMAGE" --loop
docker run -d "$@" >/dev/null

echo
echo "离线客户端起来了（$NAME）—— 它每 $(env_get CLIENT_POLL_SECONDS '300') 秒扫一次源库。"
echo "  第一次建议先看一遍「剥头 + 解密 + 导出」的报告（不连后端、不花模型的钱）："
echo "    ./stop.sh client"
echo "    docker run --rm --network $NETWORK -v \"${HOST_DIR}:/data/nt:rw\" \\"
echo "      --env-file .env $FULL_IMAGE --prepare"
echo
echo "⚠️ 同一个 QQ 账号只能有一条入库链路。既然在用客户端，"
echo "   请把 bot 的 GROUP_WHITELIST / SENDER_WHITELIST 留空（它仍然负责 /注册、/订阅、摘要推送）。"
echo
echo "  docker logs -f $NAME      # 看它每轮扫了什么"
echo "  ./stop.sh client          # 停"
