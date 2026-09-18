#!/usr/bin/env sh
# backend（栈 1）的部署预检 —— 在 ./start.sh 之前跑，把能提前发现的问题一次报完。
#
#     ./preflight.sh
#
# 只读检查：不改任何东西、不拉镜像、不起容器。
# 退出码 0 = 可以 start；1 = 有必须先处理的问题；2 = 环境本身不对（没装 docker 等）。

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || {
  echo "无法确定脚本所在目录" >&2; exit 2
}
cd "$SCRIPT_DIR" || { echo "无法进入 $SCRIPT_DIR" >&2; exit 2; }

MISSING_CMDS=''
for _c in grep awk sed; do
  command -v "$_c" >/dev/null 2>&1 || MISSING_CMDS="$MISSING_CMDS $_c"
done
if [ -n "$MISSING_CMDS" ]; then
  echo "缺少命令：$MISSING_CMDS —— 本脚本依赖它们做检查，先装上再跑。" >&2
  echo "（Debian/Ubuntu: apt-get install -y grep gawk sed；RHEL/CentOS: yum install -y grep gawk sed）" >&2
  exit 2
fi

RED=''; GRN=''; YEL=''; DIM=''; RST=''
if [ -t 1 ]; then
  RED=$(printf '\033[31m'); GRN=$(printf '\033[32m')
  YEL=$(printf '\033[33m'); DIM=$(printf '\033[2m'); RST=$(printf '\033[0m')
fi

PROBLEMS=0
WARNINGS=0

ok()   { printf '  %s✓%s %s\n' "$GRN" "$RST" "$1"; }
bad()  { printf '  %s✗%s %s\n' "$RED" "$RST" "$1"; PROBLEMS=$((PROBLEMS + 1)); }
warn() { printf '  %s!%s %s\n' "$YEL" "$RST" "$1"; WARNINGS=$((WARNINGS + 1)); }
note() { printf '      %s%s%s\n' "$DIM" "$1" "$RST"; }

# 从 .env 读一个键，读不到就用默认值。只认 KEY=VALUE，不 source（不执行里面的内容）。
env_get() {
  _key=$1; _def=$2
  if [ -f .env ]; then
    _v=$(grep -E "^[[:space:]]*${_key}=" .env 2>/dev/null | tail -n 1 | sed -e "s/^[^=]*=//" -e 's/[[:space:]]*$//')
    if [ -n "${_v:-}" ]; then printf '%s' "$_v"; return; fi
  fi
  printf '%s' "$_def"
}

# 找出谁在监听某个端口。优先 ss，退回 netstat。刻意不按列号取值（列在不同版本会变），
# 改成在整行里找 `:端口` 后面跟空白或行尾。
port_match() {
  grep -E "[:.]$1([[:space:]]|\$)"
}

port_holder() {
  _port=$1
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | port_match "$_port"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltnp 2>/dev/null | port_match "$_port"
  fi
}

port_in_use() {
  _port=$1
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | port_match "$_port" >/dev/null
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | port_match "$_port" >/dev/null
  else
    return 2   # 两个都没有：不能假装"端口是空的"
  fi
}

echo
echo "Xcollector backend 预检（栈 1：数据层）"
echo "====================================="
echo

# ---------------------------------------------------------------- 环境
echo "■ 环境"

if ! command -v docker >/dev/null 2>&1; then
  bad "没有 docker —— 先装 Docker Engine"
  note "https://docs.docker.com/engine/install/"
  echo
  echo "环境本身不对，后面的检查没法做。"
  exit 2
fi
ok "docker $(docker --version 2>/dev/null | sed 's/^Docker version //; s/,.*//')"

if docker info >/dev/null 2>&1; then
  ok "能连上 docker daemon"
else
  bad "连不上 docker daemon —— 服务没起，或当前用户不在 docker 组"
  note "试试： systemctl start docker    或    sudo usermod -aG docker \$USER（重新登录生效）"
fi

if [ "$(id -u 2>/dev/null)" = "0" ]; then
  ok "以 root 运行（能查到占用端口的进程名）"
else
  note "非 root：端口占用能查出来，但看不到是哪个进程占的"
fi
echo

# ---------------------------------------------------------------- .env
echo "■ 配置 (.env)"

if [ -f .env ]; then
  ok ".env 存在"
else
  bad ".env 不存在 —— 起容器前必须有它"
  note "先建一个： cp .env.example .env"
fi

API_TOKEN_V=$(env_get API_TOKEN '')
if [ -n "$API_TOKEN_V" ]; then
  ok "API_TOKEN 已设置（长度 ${#API_TOKEN_V}）"
  if [ "${#API_TOKEN_V}" -lt 16 ]; then
    warn "API_TOKEN 偏短，建议 32 字节随机值"
    note '生成： python3 -c "import secrets;print(secrets.token_hex(32))"'
  fi
  note "⚠️ 这个值必须和 ../bot/.env 里的 API_TOKEN 一模一样（bot 用它调本服务）"
else
  warn "API_TOKEN 为空 —— 后端将**不校验任何请求**"
  note "只在你完全信任这台机器的网络环境时才这样跑。"
  note '生成一个： python3 -c "import secrets;print(secrets.token_hex(32))"'
fi

SIGNUP_MODE_V=$(env_get SIGNUP_MODE 'invite')
case "$SIGNUP_MODE_V" in
  invite)
    ok "SIGNUP_MODE=invite（需要邀请码）"
    note "用 API_TOKEN 签发： curl -X POST http://127.0.0.1:$(env_get BACKEND_HOST_PORT '8000')/api/invites \\"
    note '     -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json" \'
    note '     -d "{\"note\":\"给谁的\",\"max_uses\":1}"'
    ;;
  open)
    warn "SIGNUP_MODE=open —— **任何能通过 QQ 验证的人都能注册**"
    note "每次注册都意味着别人可以花你的 LLM 额度、占用你的存储。"
    ;;
  *)
    bad "SIGNUP_MODE=$SIGNUP_MODE_V 不是合法值（只能是 invite / open）"
    ;;
esac

# 多用户改造之前有个"网页令牌"WEB_API_TOKEN。**两个服务都不再读它了**：
# 每个用户注册时各自签发 UserToken。留着一个还在生效的共享网页令牌是最糟的状态。
if [ -n "$(env_get WEB_API_TOKEN '')" ]; then
  warn "WEB_API_TOKEN 已废弃 —— 后端和 bot 都不再读它（现在每人一个 UserToken）"
  note "请从 .env 里删掉。用户登录用的是注册时拿到的 UserToken（xc_ 开头）。"
fi

# 附件签名：设为 0 会让证据图静默 401（图片位置空着，不报错）
TTL_V=$(env_get ATTACHMENT_URL_TTL '3600')
case "$TTL_V" in
  0)
    warn "ATTACHMENT_URL_TTL=0 —— 附件不做签名，证据图与附件下载会 401 显示不出来"
    note "浏览器 <img> 带不了 Authorization 头，必须靠签名 URL。改回 3600 或留空。"
    ;;
  ''|*[!0-9]*)
    warn "ATTACHMENT_URL_TTL=${TTL_V} 不是正整数，后端会当成无效值处理"
    ;;
  *)
    ok "附件签名 URL 有效期 ${TTL_V}s"
    ;;
esac
echo

# ---------------------------------------------------------------- 端口
echo "■ 宿主机端口"

PORT_V=$(env_get BACKEND_HOST_PORT '8000')
BIND_V=$(env_get BACKEND_BIND '127.0.0.1')

port_in_use "$PORT_V"
_rc=$?
if [ "$_rc" -eq 2 ]; then
  warn "端口 $PORT_V 无法检查（本机没有 ss 也没有 netstat）"
  note "装一个： apt-get install -y iproute2   或   yum install -y net-tools"
elif [ "$_rc" -eq 0 ]; then
  bad "端口 $PORT_V 已被占用（容器起不来）"
  _holder=$(port_holder "$PORT_V")
  if [ -n "$_holder" ]; then
    note "占用者："
    printf '%s\n' "$_holder" | sed 's/^/        /'
  fi
  note "是别的服务 → 在 .env 里改 BACKEND_HOST_PORT 换一个端口，再同步改反向代理"
  note "是上一轮的 xcollector 容器 → ./stop.sh 之后再 ./start.sh"
else
  ok "端口 $PORT_V 空闲"
fi

if [ "$BIND_V" = "0.0.0.0" ]; then
  warn "BACKEND_BIND=0.0.0.0 —— 后端会监听所有网卡（不带 TLS）"
  note "只有在 web server 位于**别的机器**、且中间有可信网络时才这样。"
else
  ok "只绑 $BIND_V（由你的 web server 反代）"
fi
echo

# ---------------------------------------------------------------- 网络与卷
echo "■ 网络与数据卷"

NETWORK_V=$(env_get XCOLLECTOR_NETWORK 'xcollector')
if docker network inspect "$NETWORK_V" >/dev/null 2>&1; then
  ok "网络 $NETWORK_V 已存在"
  note "它可能是上一轮建的；bot 栈要靠它找到本服务"
else
  note "网络 $NETWORK_V 还没有 —— ./start.sh 会建（bot 的预检会等它）"
fi

VOLUME_V=$(env_get BACKEND_VOLUME 'xcollector_backend-data')
if docker volume inspect "$VOLUME_V" >/dev/null 2>&1; then
  ok "数据卷 $VOLUME_V 已存在（里面有数据，别删）"
else
  note "数据卷 $VOLUME_V 还没有 —— ./start.sh 会建"
fi
echo

# ---------------------------------------------------------------- 镜像
echo "■ 镜像"

IMAGE_V=$(env_get IMAGE_BACKEND 'ghcr.io/xqy1y4ever/xcollector-backend')
VERSION_V=$(env_get VERSION 'latest')
FULL_IMAGE="$IMAGE_V:$VERSION_V"

case "$FULL_IMAGE" in
  *[A-Z]*) bad "镜像名含大写：$FULL_IMAGE"
           note "GHCR 只接受全小写路径，用户名里的 Xqy1y4ever 必须写成 xqy1y4ever" ;;
  *)
    if docker image inspect "$FULL_IMAGE" >/dev/null 2>&1; then
      ok "镜像本地已有：$FULL_IMAGE"
    elif docker manifest inspect "$FULL_IMAGE" >/dev/null 2>&1; then
      ok "镜像远端可拉：$FULL_IMAGE"
    else
      warn "镜像拉不到：$FULL_IMAGE"
      note "本地没有、远端也查不到。可能还没构建完，或仓库是 private 而你没登录。"
      note "看看 CI 有没有跑成功，或手动试： docker pull $FULL_IMAGE"
    fi ;;
esac

PULL_POLICY_V=$(env_get PULL_POLICY 'always')
if [ "$PULL_POLICY_V" != "always" ] && [ "$VERSION_V" = "latest" ]; then
  note "PULL_POLICY=$PULL_POLICY_V + VERSION=latest：不会自动升级"
  note "想跟着最新走就设 PULL_POLICY=always，或升级时手动 docker pull"
fi
echo

# ---------------------------------------------------------------- 运行中的容器
# 容器的环境变量在**创建那一刻**就固定了：改了 .env 不重建容器就不会生效 ——
# 这是最难查的一类问题（程序看起来"没读到 .env"）。这里直接比。
NAME=xcollector-backend
if docker container inspect "$NAME" >/dev/null 2>&1; then
  C_ENV=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$NAME" 2>/dev/null)
  if [ -z "$C_ENV" ]; then
    warn "读不到运行中容器的环境变量，跳过一致性检查"
  else
    # 只比这几个：它们应该来自 .env，而且 start.sh 的 -e 没有覆盖它们。
    COMPARE_KEYS="API_TOKEN SIGNUP_MODE ATTACHMENT_URL_TTL MEDIA_MAX_BYTES LOG_LEVEL"
    SECRET_KEYS=" API_TOKEN ATTACHMENT_SIGN_KEY "
    STALE=0; STALE_KEYS=''
    for _k in $COMPARE_KEYS; do
      _want=$(env_get "$_k" '')
      _got=$(printf '%s\n' "$C_ENV" | sed -n "s/^${_k}=//p" | head -n 1)
      [ "$_want" = "$_got" ] && continue
      STALE=$((STALE + 1)); STALE_KEYS="$STALE_KEYS $_k"
    done
    if [ "$STALE" -gt 0 ]; then
      bad "运行中的容器里有 $STALE 项配置与 .env 不一致"
      for _k in $STALE_KEYS; do
        case "$SECRET_KEYS" in
          *" $_k "*) note "$_k：两边不一致（值已隐去）" ;;
          *)
            _want=$(env_get "$_k" ''); _got=$(printf '%s\n' "$C_ENV" | sed -n "s/^${_k}=//p" | head -n 1)
            note "$_k：容器里是 '${_got}'，.env 里是 '${_want}'" ;;
        esac
      done
      note "解决： ./start.sh（它会重建容器；数据在卷里，不会丢）"
    else
      ok "运行中的容器与 .env 一致"
    fi
  fi
else
  note "还没有运行中的 $NAME 容器"
fi
echo

# ---------------------------------------------------------------- 结论
echo "====================================="
if [ "$PROBLEMS" -gt 0 ]; then
  printf '%s必须先处理 %d 个问题%s（另有 %d 条提醒）\n' "$RED" "$PROBLEMS" "$RST" "$WARNINGS"
  echo "处理完再跑一次本脚本，全绿了再 ./start.sh"
  exit 1
fi

if [ "$WARNINGS" -gt 0 ]; then
  printf '%s可以启动%s，但有 %d 条提醒值得看一眼。\n' "$YEL" "$RST" "$WARNINGS"
else
  printf '%s全部通过。%s\n' "$GRN" "$RST"
fi

echo
echo "接下来："
echo "  ./start.sh                    # 起 backend（会建网络与数据卷、等健康检查）"
echo "  cd ../bot && ./start.sh       # 再起 bot（它要用本栈建的 xcollector 网络）"
echo
echo "还没做的话别忘反向代理： / 指向 dist/ 静态文件，/api/ 指向 127.0.0.1:${PORT_V}"
echo "（前缀保留，并且要**原样转发 Authorization 头**）。"
echo
exit 0
