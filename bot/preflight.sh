#!/usr/bin/env sh
# bot（栈 2）的部署预检 —— 在 ./start.sh 之前跑。
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

env_get() {
  _key=$1; _def=$2
  if [ -f .env ]; then
    _v=$(grep -E "^[[:space:]]*${_key}=" .env 2>/dev/null | tail -n 1 | sed -e "s/^[^=]*=//" -e 's/[[:space:]]*$//')
    if [ -n "${_v:-}" ]; then printf '%s' "$_v"; return; fi
  fi
  printf '%s' "$_def"
}

port_match() { grep -E "[:.]$1([[:space:]]|\$)"; }

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
    return 2
  fi
}

echo
echo "Xcollector bot 预检（栈 2：消息处理层）"
echo "======================================"
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
echo

# ---------------------------------------------------------------- 网络（栈间唯一的连接）
echo "■ 与 backend 的连接"

NETWORK_V=$(env_get XCOLLECTOR_NETWORK 'xcollector')
if docker network inspect "$NETWORK_V" >/dev/null 2>&1; then
  ok "Docker 网络 $NETWORK_V 存在"
  if docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' "$NETWORK_V" 2>/dev/null | grep -q xcollector-backend; then
    ok "backend 容器就在这张网络里"
  else
    warn "这张网络里没看到 xcollector-backend"
    note "先起后端： cd ../backend && ./start.sh"
    note "（后端没起也不会让 bot 崩，只是收不到/写不进任何东西。）"
  fi
else
  bad "找不到 Docker 网络 $NETWORK_V —— **先起 backend**，是它建的这张网络"
  note "    cd ../backend && ./start.sh"
  note "两个容器靠这张网络互相找到（BACKEND_BASE_URL 里的主机名要能在它里面解析）。"
fi

BACKEND_URL_V=$(env_get BACKEND_BASE_URL 'http://xcollector-backend:8000')
# 从 URL 里抠出主机名（去掉协议、路径、端口）。
BACKEND_HOST=$(printf '%s' "$BACKEND_URL_V" | sed -e 's|^[a-zA-Z][a-zA-Z0-9+.-]*://||' -e 's|/.*$||' -e 's|:.*$||')

case "$BACKEND_HOST" in
  ''|localhost|127.0.0.1)
    warn "BACKEND_BASE_URL 指向 $BACKEND_URL_V —— 容器里的 localhost 是容器自己，不是后端"
    note "两个容器之间要用**容器名**： http://xcollector-backend:8000"
    ;;
  *.*)
    # 带点的当域名/IP：后端在别的机器上时正常，这里不做解析检查
    note "BACKEND_BASE_URL=$BACKEND_URL_V（看起来是域名/IP —— 后端在别的机器上时这样是对的）"
    ;;
  *)
    # 单段主机名 → 必须能在 xcollector 网络里解析，否则运行时报
    # `[Errno -2] Name or service not known`（指令报错、状态页说后端不可达）。
    #
    # ⚠️ 这里是踩过的坑：compose 会把**服务名**注册成网络别名，而 `docker run`
    #    只注册**容器名**。所以 compose 时代写的 http://backend:8000 换成
    #    docker run 之后就解析不了了。优先用真的解析一次来判定。
    RESOLVED=0
    if docker container inspect xcollector-bot >/dev/null 2>&1; then
      # 最直接的判定：在 bot 容器里真解析一次
      if docker exec xcollector-bot python -c \
          "import socket,sys; socket.getaddrinfo('$BACKEND_HOST', 8000); sys.exit(0)" >/dev/null 2>&1; then
        RESOLVED=1
      fi
    else
      # bot 还没起：退一步看那张网络里有哪些名字（容器名 + 别名）
      NAMES=$(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' "$NETWORK_V" 2>/dev/null)
      for _c in $NAMES; do
        NAMES="$NAMES$(docker inspect -f '{{range .NetworkSettings.Networks}}{{range .Aliases}}{{.}} {{end}}{{end}}' "$_c" 2>/dev/null)"
      done
      case " $NAMES " in
        *" $BACKEND_HOST "*) RESOLVED=1 ;;
      esac
    fi

    if [ "$RESOLVED" = "1" ]; then
      ok "BACKEND_BASE_URL 的主机名 $BACKEND_HOST 能在网络 $NETWORK_V 里解析"
    else
      bad "BACKEND_BASE_URL 的主机名「$BACKEND_HOST」在 Docker 网络 $NETWORK_V 里解析不了"
      note "运行时的表现是：指令报错、状态页说「后端不可达」，日志里是"
      note "  ConnectError: [Errno -2] Name or service not known"
      note "原因：compose 会把服务名注册成网络别名，而 docker run 只注册**容器名**。"
      note "解决（任选一个）："
      note "  1) 把 .env 里的 BACKEND_BASE_URL 改成 http://xcollector-backend:8000（推荐）"
      note "  2) 重新起 backend（它的 start.sh 现在会带 --network-alias backend）："
      note "     cd ../backend && ./start.sh"
    fi
    ;;
esac
echo

# ---------------------------------------------------------------- .env 与令牌
echo "■ 配置 (.env)"

if [ -f .env ]; then
  ok ".env 存在"
else
  bad ".env 不存在 —— 起容器前必须有它"
  note "先建一个： cp .env.example .env"
fi

API_TOKEN_V=$(env_get API_TOKEN '')
BACKEND_ENV=../backend/.env
if [ -n "$API_TOKEN_V" ]; then
  ok "API_TOKEN 已设置（长度 ${#API_TOKEN_V}）"
  if [ -f "$BACKEND_ENV" ]; then
    BACKEND_TOKEN=$(grep -E "^[[:space:]]*API_TOKEN=" "$BACKEND_ENV" 2>/dev/null | tail -n 1 | sed -e "s/^[^=]*=//" -e 's/[[:space:]]*$//')
    if [ -z "${BACKEND_TOKEN:-}" ]; then
      warn "../backend/.env 里的 API_TOKEN 是空的（那边不校验任何请求）"
      note "两边不一致时 bot 调后端会 401，而日志里只说「后端拒绝了」。"
    elif [ "$BACKEND_TOKEN" = "$API_TOKEN_V" ]; then
      ok "与 ../backend/.env 里的 API_TOKEN 一致"
    else
      bad "与 ../backend/.env 里的 API_TOKEN **不一致** —— bot 调后端会全部 401"
      note "两个栈各自一个 .env，但 API_TOKEN 必须是同一个值（值已隐去，只比是否相等）。"
    fi
  else
    note "没找到 ../backend/.env（后端在别的机器上时正常）—— 请自行确认两边 API_TOKEN 一致"
  fi
else
  warn "API_TOKEN 为空 —— 调后端时不会带令牌，后端若配了令牌就会全部 401"
  note '生成一个，并写进**两个** .env： python3 -c "import secrets;print(secrets.token_hex(32))"'
fi

SIGNUP_MODE_V=$(env_get SIGNUP_MODE '')
if [ -n "$SIGNUP_MODE_V" ]; then
  note "SIGNUP_MODE 属于 backend 的配置，写在这个 .env 里不生效（那边有自己的 .env）"
fi
WEB_API_TOKEN_V=$(env_get WEB_API_TOKEN '')
if [ -n "$WEB_API_TOKEN_V" ]; then
  warn "WEB_API_TOKEN 已废弃 —— 后端与 bot 都不再读它（现在每人一个 UserToken）"
  note "请从 .env 里删掉。"
fi
echo

# ---------------------------------------------------------------- OneBot
echo "■ OneBot / NapCat"

ONEBOT_MODE_V=$(env_get ONEBOT_MODE 'client')
case "$ONEBOT_MODE_V" in
  client)
    ok "ONEBOT_MODE=client（bot 主动连 NapCat）"
    WS_V=$(env_get ONEBOT_WS_URL 'ws://host.docker.internal:3001')
    note "NapCat 的 WS 地址：$WS_V"
    case "$WS_V" in
      ws://host.docker.internal*|ws://127.0.0.1*|ws://localhost*)
        note "start.sh 已经加了 --add-host host.docker.internal:host-gateway，"
        note "容器里能用这个名字找到宿主机（Linux 上也行）。" ;;
      *) note "NapCat 在别的机器上时，这个地址要是那台机器能连上的地址。" ;;
    esac
    ;;
  server)
    ok "ONEBOT_MODE=server（NapCat 反向连过来）"
    note "NapCat 里填： ws://<本机>:$(env_get ONEBOT_HOST_PORT '8081')$(env_get ONEBOT_LISTEN_PATH '/onebot/ws')"
    ;;
  *)
    bad "ONEBOT_MODE=$ONEBOT_MODE_V 不是合法值（只能是 client / server）"
    ;;
esac

if [ -n "$(env_get ONEBOT_ACCESS_TOKEN '')" ]; then
  ok "ONEBOT_ACCESS_TOKEN 已设置（要和 NapCat 里配的那个一致）"
else
  note "ONEBOT_ACCESS_TOKEN 为空 = 不校验（NapCat 那边配了 token 时这里也必须填）"
fi
echo

# ---------------------------------------------------------------- 白名单与抽取
echo "■ 白名单与抽取"

GROUP_WHITELIST_V=$(env_get GROUP_WHITELIST '')
if [ -z "$GROUP_WHITELIST_V" ]; then
  bad "GROUP_WHITELIST 为空 —— bot 会**忽略所有群的消息**"
  note "白名单是 fail-closed 的：留空不等于「全收」，等于「一个都不收」。"
  note "填上要处理的群： GROUP_WHITELIST=123456789:官方通知群"
else
  ok "GROUP_WHITELIST 已设置"
fi

SENDER_MODE_V=$(env_get SENDER_WHITELIST_MODE 'strict')
if [ "$SENDER_MODE_V" = "off" ]; then
  warn "SENDER_WHITELIST_MODE=off —— 白名单群里**谁发的消息都会被处理**"
  note "官方通知一般只由固定几个人发布。确认这是你要的，否则改成 strict 并配 SENDER_WHITELIST。"
elif [ -z "$(env_get SENDER_WHITELIST '')" ]; then
  bad "SENDER_WHITELIST 为空 —— bot 会**忽略所有发送者的消息**"
  note "填上发布通知的人： SENDER_WHITELIST=10001:张老师"
  note "（这个群里谁发的都该收的话，把 SENDER_WHITELIST_MODE 设成 off —— 那是显式放开。）"
else
  ok "SENDER_WHITELIST 已设置（mode=$SENDER_MODE_V）"
fi

EXTRACTOR_V=$(env_get EXTRACTOR 'llm')
case "$EXTRACTOR_V" in
  rule) ok "EXTRACTOR=rule（不调用模型，不需要 API key）" ;;
  llm|both)
    if [ -n "$(env_get LLM_PRIMARY_API_KEY '')" ] \
       || [ -n "$(env_get DEEPSEEK_API_KEY '')" ] || [ -n "$(env_get OPENAI_API_KEY '')" ] \
       || [ -n "$(env_get GEMINI_API_KEY '')" ] || [ -n "$(env_get GOOGLE_API_KEY '')" ]; then
      ok "EXTRACTOR=$EXTRACTOR_V，且配了至少一个 key"
    else
      bad "EXTRACTOR=$EXTRACTOR_V 但一个模型 API key 都没配"
      note "抽取会全部失败并降级为规则抽取。可以按提供商配环境变量"
      note "（LLM_PRIMARY_PROVIDER=deepseek → DEEPSEEK_API_KEY），或用 LLM_PRIMARY_API_KEY 指定。"
    fi ;;
  *) bad "EXTRACTOR=$EXTRACTOR_V 不是合法值（只能是 rule / llm / both）" ;;
esac

if [ -z "$(env_get COMMAND_WHITELIST '')" ]; then
  ok "COMMAND_WHITELIST 为空 = 除 /注册、/help 外谁都不能发指令（安全的默认值）"
else
  ok "COMMAND_WHITELIST 已设置"
fi

DIGEST_ENABLED_V=$(env_get DIGEST_ENABLED 'true')
if [ "$DIGEST_ENABLED_V" = "true" ] && [ -z "$(env_get DIGEST_TARGET_QQ '')" ]; then
  note "DIGEST_ENABLED=true 且 DIGEST_TARGET_QQ 留空 = 每个注册用户各收自己那份（推荐）"
fi

# 离线客户端（可选）。配了就检查，没配就跳过。
CLIENT_HOST_DIR=$(env_get CLIENT_NT_MSG_HOST_DIR '')
CLIENT_TOKEN_V=$(env_get CLIENT_TOKEN '')
CLIENT_KEY_V=$(env_get CLIENT_NT_MSG_KEY '')
CLIENT_KEY_FILE_V=$(env_get CLIENT_NT_MSG_KEY_FILE '')
CLIENT_DB_PATH_V=$(env_get CLIENT_DB_PATH '')

if [ -n "$CLIENT_HOST_DIR" ] || [ -n "$CLIENT_TOKEN_V" ] || [ -n "$CLIENT_KEY_V" ]; then
  echo
  echo "■ 离线客户端（可选： ./start.sh client）"

  if [ -z "$CLIENT_HOST_DIR" ]; then
    bad "配了 CLIENT_TOKEN 但没配 CLIENT_NT_MSG_HOST_DIR —— 客户端没有源库可读"
  elif [ ! -d "$CLIENT_HOST_DIR" ]; then
    bad "CLIENT_NT_MSG_HOST_DIR 不是目录或不存在：$CLIENT_HOST_DIR"
  else
    if [ ! -w "$CLIENT_HOST_DIR" ]; then
      bad "那个目录不可写：$CLIENT_HOST_DIR"
      note "A 方案（给 nt_msg.db）的解密产物要写在它旁边。"
    fi
    if [ -f "$CLIENT_HOST_DIR/nt_msg.db" ]; then
      ok "源库存在（A 方案）：$CLIENT_HOST_DIR/nt_msg.db"
      if [ -z "$CLIENT_KEY_V" ] && [ -z "$CLIENT_KEY_FILE_V" ]; then
        bad "A 方案没配密钥：CLIENT_NT_MSG_KEY 与 CLIENT_NT_MSG_KEY_FILE 都是空的"
        note "密钥是 NTQQ 解密那个库用的 16 个 ASCII 字符，用 QQBackup/qq-win-db-key 自己取。"
      elif [ -n "$CLIENT_KEY_FILE_V" ]; then
        if [ -f "$CLIENT_KEY_FILE_V" ]; then
          ok "密钥来自文件：$CLIENT_KEY_FILE_V"
        else
          bad "CLIENT_NT_MSG_KEY_FILE 指向的文件不存在：$CLIENT_KEY_FILE_V"
        fi
      else
        ok "密钥来自 CLIENT_NT_MSG_KEY（${#CLIENT_KEY_V} 个字符）"
        if [ "${#CLIENT_KEY_V}" -ne 16 ]; then
          warn "密钥长度是 ${#CLIENT_KEY_V}，不是 16 —— QQ 的密钥应该是 16 个 ASCII 字符"
        fi
      fi
    elif [ -f "$CLIENT_HOST_DIR/nt_msg_export.db" ]; then
      ok "源库存在（B 方案）：$CLIENT_HOST_DIR/nt_msg_export.db"
      if [ "$CLIENT_DB_PATH_V" != "/data/nt/nt_msg_export.db" ]; then
        warn "CLIENT_DB_PATH 现在是 '${CLIENT_DB_PATH_V}'，B 方案应设成 /data/nt/nt_msg_export.db"
      fi
    else
      bad "那个目录里既没有 nt_msg.db 也没有 nt_msg_export.db：$CLIENT_HOST_DIR"
      note "A 方案：放 QQ 的加密原始库 nt_msg.db（客户端自己剥头/解密/导出）"
      note "B 方案：放 nt_msg_export.db，并把 CLIENT_DB_PATH 设成 /data/nt/nt_msg_export.db"
    fi
  fi

  if [ -z "$CLIENT_TOKEN_V" ]; then
    warn "配了源库目录但没配 CLIENT_TOKEN —— 客户端会以未认证身份请求，全部 401"
  else
    case "$CLIENT_TOKEN_V" in
      xc_*) ok "客户端用的是 UserToken（xc_ 开头）" ;;
      *)
        warn "CLIENT_TOKEN 不是 xc_ 开头 —— 它看起来是**服务令牌**（API_TOKEN）"
        note "用服务令牌跑客户端意味着那个容器能读写**所有人**的数据。"
        note "正确做法：让用户在 QQ 里给机器人发 /注册，在网页上注册后拿到的 UserToken。"
        ;;
    esac
  fi

  if [ -n "$GROUP_WHITELIST_V" ] || [ -n "$(env_get SENDER_WHITELIST '')" ]; then
    warn "bot 的白名单非空，而你配了离线客户端 —— 两条入库链路同时开会让同一条消息变成两条"
    note "只用客户端的话，把 GROUP_WHITELIST 与 SENDER_WHITELIST 留空"
    note "（bot 就不处理任何消息，但仍然负责 /注册、/订阅、摘要推送）。"
  fi
fi
echo

# ---------------------------------------------------------------- 端口
echo "■ 宿主机端口"

check_port() {
  _name=$1; _port=$2; _var=$3
  port_in_use "$_port"
  _rc=$?
  if [ "$_rc" -eq 2 ]; then
    warn "$_name 端口 $_port 无法检查（本机没有 ss 也没有 netstat）"
    note "装一个： apt-get install -y iproute2   或   yum install -y net-tools"
    return 0
  fi
  if [ "$_rc" -eq 0 ]; then
    bad "$_name 端口 $_port 已被占用（容器起不来）"
    _holder=$(port_holder "$_port")
    if [ -n "$_holder" ]; then
      note "占用者："
      printf '%s\n' "$_holder" | sed 's/^/        /'
    fi
    note "是别的服务 → 在 .env 里改 $_var 换一个端口"
    note "是上一轮的 xcollector 容器 → ./stop.sh 之后再 ./start.sh"
    return 1
  fi
  ok "$_name 端口 $_port 空闲"
  return 0
}

BOT_P=$(env_get BOT_HOST_PORT '8082')
ONEBOT_P=$(env_get ONEBOT_HOST_PORT '8081')
check_port "bot HTTP" "$BOT_P" "BOT_HOST_PORT"
if [ "$ONEBOT_MODE_V" = "server" ]; then
  check_port "bot 反向 WS" "$ONEBOT_P" "ONEBOT_HOST_PORT"
else
  note "ONEBOT_MODE=$ONEBOT_MODE_V（正向 WS），$ONEBOT_P 只在 server 模式才需要，跳过"
fi
if [ "$BOT_P" = "$ONEBOT_P" ]; then
  bad "BOT_HOST_PORT 与 ONEBOT_HOST_PORT 相同 —— 两个端口必须不同"
fi
echo

# ---------------------------------------------------------------- 镜像
echo "■ 镜像"

check_image() {
  _name=$1; _full=$2
  case "$_full" in
    *[A-Z]*) bad "$_name 镜像名含大写：$_full"
             note "GHCR 只接受全小写路径，用户名里的 Xqy1y4ever 必须写成 xqy1y4ever" ;;
    *)
      if docker image inspect "$_full" >/dev/null 2>&1; then
        ok "$_name 镜像本地已有：$_full"
      elif docker manifest inspect "$_full" >/dev/null 2>&1; then
        ok "$_name 镜像远端可拉：$_full"
      else
        warn "$_name 镜像拉不到：$_full"
        note "本地没有、远端也查不到。可能还没构建完，或仓库是 private 而你没登录。"
      fi ;;
  esac
}

VERSION_V=$(env_get VERSION 'latest')
check_image "bot" "$(env_get IMAGE_BOT 'ghcr.io/xqy1y4ever/xcollector-bot'):$VERSION_V"
if [ -n "$CLIENT_HOST_DIR" ]; then
  check_image "client" "$(env_get IMAGE_CLIENT 'ghcr.io/xqy1y4ever/xcollector-client'):$VERSION_V"
fi

PULL_POLICY_V=$(env_get PULL_POLICY 'always')
if [ "$PULL_POLICY_V" != "always" ] && [ "$VERSION_V" = "latest" ]; then
  note "PULL_POLICY=$PULL_POLICY_V + VERSION=latest：不会自动升级"
  note "想跟着最新走就设 PULL_POLICY=always，或升级时手动 docker pull"
fi
echo

# ---------------------------------------------------------------- 运行中的容器
NAME=xcollector-bot
if docker container inspect "$NAME" >/dev/null 2>&1; then
  C_ENV=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$NAME" 2>/dev/null)
  if [ -z "$C_ENV" ]; then
    warn "读不到运行中容器的环境变量，跳过一致性检查"
    note "手动确认： docker exec $NAME printenv ONEBOT_WS_URL GROUP_WHITELIST EXTRACTOR"
  else
    # 只比这几个：它们来自 .env，而 start.sh 的 -e 没有覆盖它们
    # （BACKEND_BASE_URL / *_LISTEN_* / TZ 是被覆盖的，比了必然"不一致"，是噪音）。
    COMPARE_KEYS="ONEBOT_MODE ONEBOT_WS_URL ONEBOT_ACCESS_TOKEN EXTRACTOR GROUP_WHITELIST DIGEST_ENABLED API_TOKEN"
    SECRET_KEYS=" ONEBOT_ACCESS_TOKEN API_TOKEN "
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
      note "原因：容器的环境变量在**创建那一刻**就固定了，改 .env 不会自动同步。"
      note "解决： ./start.sh（它会重建容器；bot 没有需要保留的本地状态）"
    else
      ok "运行中的容器与 .env 一致"
    fi
  fi
else
  note "还没有运行中的 $NAME 容器"
fi
echo

# ---------------------------------------------------------------- 结论
echo "======================================"
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
echo "  ./start.sh            # 起 bot"
echo "  ./start.sh client     # 或：起离线客户端（读聊天记录库入库，不连 QQ）"
echo
echo "bot 的 127.0.0.1:${BOT_P} **不要**反代到公网 —— 那是运营者的管理接口。"
echo "第一次用要先注册：在 QQ 里给机器人发 /注册，再把验证码拿到网页上完成注册。"
echo
exit 0
