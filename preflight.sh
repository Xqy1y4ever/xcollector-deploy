#!/usr/bin/env sh
# Xcollector 部署预检 —— 在 `docker compose up` 之前跑，把能提前发现的问题一次报完。
#
#     sh preflight.sh
#
# 为什么需要它：`docker compose up` 是「跑完才知道」—— 端口被占、.env 没建、
# API_TOKEN 忘了填，都要等容器建完才报，而且一次只报一个。这些在启动前就能查。
#
# 只读检查：不改任何东西、不拉镜像、不启容器。
# 退出码 0 = 可以 up；1 = 有必须先处理的问题；2 = 环境本身不对（没装 docker 等）。

set -u

# 切到脚本自己所在的目录。本脚本要读同目录的 .env 和 docker-compose.yml，
# 如果不切，`sh /path/to/preflight.sh` 从别处调用时相对路径就找不到了。
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || {
  echo "无法确定脚本所在目录" >&2; exit 2
}
cd "$SCRIPT_DIR" || { echo "无法进入 $SCRIPT_DIR" >&2; exit 2; }

# 这些命令在正常 Linux 上都有（busybox 也提供），缺了就没法检查 —— 提前说清楚，
# 免得后面静默地把"查不出"当成"没问题"。
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

# 从 .env 读一个键，读不到就用默认值。只认 KEY=VALUE 且不处理引号 —— 够用，
# 而且不会像 source 那样执行 .env 里的内容。
env_get() {
  _key=$1; _def=$2
  if [ -f .env ]; then
    _v=$(grep -E "^[[:space:]]*${_key}=" .env 2>/dev/null | tail -n 1 | sed -e "s/^[^=]*=//" -e 's/[[:space:]]*$//')
    if [ -n "${_v:-}" ]; then printf '%s' "$_v"; return; fi
  fi
  printf '%s' "$_def"
}

# 找出谁在监听某个端口。优先 ss，退回 netstat。打印原始行，找不到就返回 1。
#
# 刻意**不按列号取值**（不用 awk '$4'）：ss / netstat 的输出列在不同版本、
# 不同内核下会变，取错列的结果是静默报"端口空闲"。改成在整行里找
# `:端口` 后面跟空白或行尾 —— 监听方的本地地址一定匹配，而对方的
# `0.0.0.0:*` 端口是 `*`，不会误报。
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
  # 注意 >/dev/null：这里只关心"有没有"，匹配到的原始行不能漏到输出里，
  # 否则会插在标题下面，看着像脚本自己出了毛病。
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | port_match "$_port" >/dev/null
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | port_match "$_port" >/dev/null
  else
    # 两个命令都没有：不能假装"端口是空的" —— 那等于把检查关掉了。
    return 2
  fi
}

echo
echo "Xcollector 部署预检"
echo "==================="
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

if docker compose version >/dev/null 2>&1; then
  ok "docker compose $(docker compose version --short 2>/dev/null)"
elif command -v docker-compose >/dev/null 2>&1; then
  warn "只有旧的 docker-compose（v1）—— 本编排用了 \`name:\` 顶层字段和"
  note "depends_on 的 condition 形式，v1 会报错。请用 \`docker compose\`（v2 插件）"
else
  bad "没有 docker compose 插件"
fi

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
  bad ".env 不存在 —— compose 读不到任何配置"
  note "先建一个： cp .env.example .env"
fi

API_TOKEN_V=$(env_get API_TOKEN '')
if [ -n "$API_TOKEN_V" ]; then
  ok "API_TOKEN 已设置（长度 ${#API_TOKEN_V}）"
  if [ "${#API_TOKEN_V}" -lt 16 ]; then
    warn "API_TOKEN 偏短，建议 32 字节随机值"
    note '生成： python3 -c "import secrets;print(secrets.token_hex(32))"'
  fi
else
  warn "API_TOKEN 为空 —— 后端将**不校验任何请求**"
  note "只在你完全信任这台机器的网络环境时才这样跑。"
  note '生成一个： python3 -c "import secrets;print(secrets.token_hex(32))"'
fi

# 注册方式：决定"谁能用这个服务"。默认邀请码制 —— 每次注册都意味着别人可以花
# 你的 LLM 额度、占你的存储，所以默认关着。
SIGNUP_MODE_V=$(env_get SIGNUP_MODE 'invite')
case "$SIGNUP_MODE_V" in
  invite)
    ok "SIGNUP_MODE=invite（需要邀请码）"
    note "用 API_TOKEN 签发： curl -X POST http://127.0.0.1:8000/api/invites \\"
    note '     -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json" \'
    note '     -d "{\"note\":\"给谁的\",\"max_uses\":1}"'
    ;;
  open)
    warn "SIGNUP_MODE=open —— **任何能通过 QQ 验证的人都能注册**"
    note "每次注册都意味着别人可以花你的 LLM 额度、占用你的存储。"
    note "建议改成 invite，或用配额/审批兜住。"
    ;;
  *)
    bad "SIGNUP_MODE=$SIGNUP_MODE_V 不是合法值（只能是 invite / open）"
    ;;
esac

# 旧配置里可能还留着 WEB_API_TOKEN（多用户改造之前是"网页令牌"）。
# **现在两个服务都不再读它了**：每个用户注册时各自签发 UserToken，
# 而 bot 自己的 /api/* 只认管理令牌（API_TOKEN / BOT_API_TOKEN）。
# 留着一个还在生效的共享网页令牌是最糟的状态 —— 这里刻意说清"它已经无效"。
if [ -n "$(env_get WEB_API_TOKEN '')" ]; then
  warn "WEB_API_TOKEN 已废弃 —— 后端和 bot 都不再读它（现在每人一个 UserToken）"
  note "请从 .env 里删掉。留着不会报错，但会让人以为还有这么一个共享令牌在生效。"
  note "用户登录用的是注册时拿到的 UserToken（xc_ 开头），不是这个值。"
fi

# --------------------------------------------------------------------------
# 入库客户端（可选，compose profile `client`）
#
# 它读宿主机上的一个聊天记录库，用**某个用户自己的 UserToken** 写后端。
# 这里只检查"配了的话别配错"，没配就跳过 —— 它是可选的。
# --------------------------------------------------------------------------
CLIENT_DB=$(env_get CLIENT_DB_HOST_PATH '')
CLIENT_TOK=$(env_get CLIENT_TOKEN '')
if [ -n "$CLIENT_DB" ] || [ -n "$CLIENT_TOK" ]; then
  if [ -z "$CLIENT_DB" ]; then
    bad "配了 CLIENT_TOKEN 但没配 CLIENT_DB_HOST_PATH —— 客户端没有源库可读"
  elif [ ! -f "$CLIENT_DB" ]; then
    bad "CLIENT_DB_HOST_PATH 指向的文件不存在：$CLIENT_DB"
    note "它要指向 nt_msg_db_util 的 **3.export.py** 产出的 nt_msg_export.db（明文 SQLite）。"
    note "注意不是 nt_msg.db（加密），也不是 nt_msg_plain.db（正文还是 Protobuf）。"
  else
    ok "客户端源库存在：$CLIENT_DB"
    case "$CLIENT_DB" in
      *nt_msg_export.db) ;;
      *) note "路径里没有 nt_msg_export.db —— 确认你给的是 3.export.py 的产物；给错了库客户端会明确报出来。" ;;
    esac
  fi

  if [ -z "$CLIENT_TOK" ]; then
    warn "配了 CLIENT_DB_HOST_PATH 但没配 CLIENT_TOKEN —— 客户端会以未认证身份请求，全部 401"
  else
    case "$CLIENT_TOK" in
      xc_*) ok "客户端用的是 UserToken（xc_ 开头）" ;;
      *)
        warn "CLIENT_TOKEN 不是 xc_ 开头 —— 它看起来是**服务令牌**（API_TOKEN）"
        note "用服务令牌跑客户端意味着那个容器能读写**所有人**的数据，与「每人一个客户端」相悖。"
        note "正确做法：让用户在 QQ 里给机器人发 /注册，在网页上注册后拿到的 UserToken。"
        ;;
    esac
  fi

  # 两条入库链路同时开 = 同一条消息入库两次。
  # 两边的 message_id 格式不同（OneBot 的 vs ntqq:<msg_id>），幂等键拦不住。
  warn "客户端和 bot 会同时入库：同一条消息会变成两条原始记录 + 两条通知"
  note "同一个 QQ 账号只能留一条入库链路。只用客户端的话，把 GROUP_WHITELIST 与"
  note "SENDER_WHITELIST 留空（bot 就不处理任何消息），它仍然负责 /注册、/订阅、摘要推送。"
else
  note "没有配置入库客户端（compose 里用 --profile client 才启用）。"
fi

# 附件签名：设为 0 会让证据图静默 401（图片位置空着，不会报错）
TTL_V=$(env_get ATTACHMENT_URL_TTL '3600')
case "$TTL_V" in
  0)
    warn "ATTACHMENT_URL_TTL=0 —— 附件不做签名，证据图和附件下载会 401 显示不出来"
    note "浏览器 <img> 带不了 Authorization 头，所以必须靠签名 URL。改回 3600 或留空。"
    ;;
  ''|*[!0-9]*)
    warn "ATTACHMENT_URL_TTL=${TTL_V} 不是正整数，后端会当成无效值处理"
    ;;
  *)
    ok "附件签名 URL 有效期 ${TTL_V}s"
    ;;
esac

# --------------------------------------------------------------------------
# 运行中的容器拿到的是不是这份 .env 里的值？
#
# 容器的环境变量在**创建那一刻**就固定了：`docker compose restart` 只是重启进程，
# 不会重读 .env；`docker compose up -d` 在 compose 认为服务定义没变时也不会重建。
# 于是"改了 .env 却没生效"成了最难查的一类问题 —— 程序看起来"没读到 .env"，
# 其实是容器里装的还是旧值。
#
# 这里直接拿容器实际的 env 和 .env 比。（用 docker inspect 而不是 exec：
# inspect 是纯读，不会在容器里起进程。）
# --------------------------------------------------------------------------
if docker compose ps -q bot >/dev/null 2>&1; then
  BOT_CID=$(docker compose ps -q bot 2>/dev/null | head -n 1)
else
  BOT_CID=''
fi

if [ -n "$BOT_CID" ]; then
  C_ENV=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$BOT_CID" 2>/dev/null)

  if [ -z "$C_ENV" ]; then
    # inspect 失败 / 拿不到环境：绝不能当成"全都不一致"报出去 —— 那是假警报。
    warn "读不到运行中 bot 容器的环境变量，跳过一致性检查"
    note "手动确认： docker compose exec bot printenv ONEBOT_WS_URL ONEBOT_ACCESS_TOKEN"
    C_ENV=''
  else
    # 只比这些键：它们应该来自 .env，而且**没有**被 docker-compose.yml 的
    # environment 段覆盖。BACKEND_BASE_URL / *_LISTEN_* / TZ 是被覆盖的（那是刻意的），
    # 比了必然"不一致"，只是噪音。
    COMPARE_KEYS="ONEBOT_MODE ONEBOT_WS_URL ONEBOT_ACCESS_TOKEN EXTRACTOR GROUP_WHITELIST DIGEST_ENABLED API_TOKEN"
    SECRET_KEYS=" ONEBOT_ACCESS_TOKEN API_TOKEN "

    STALE=0
    STALE_KEYS=''
    for _k in $COMPARE_KEYS; do
      _want=$(env_get "$_k" '')
      _got=$(printf '%s\n' "$C_ENV" | sed -n "s/^${_k}=//p" | head -n 1)
      [ "$_want" = "$_got" ] && continue
      STALE=$((STALE + 1))
      STALE_KEYS="$STALE_KEYS $_k"
    done

    if [ "$STALE" -gt 0 ]; then
      bad "运行中的 bot 容器里有 $STALE 项配置与 .env 不一致"
      for _k in $STALE_KEYS; do
        case "$SECRET_KEYS" in
          *" $_k "*)
            note "$_k：两边不一致（值已隐去）"
            ;;
          *)
            _want=$(env_get "$_k" '')
            _got=$(printf '%s\n' "$C_ENV" | sed -n "s/^${_k}=//p" | head -n 1)
            note "$_k：容器里是 '${_got}'，.env 里是 '${_want}'"
            ;;
        esac
      done
      note "原因：容器的环境变量在**创建那一刻**就固定了，改 .env 不会自动同步。"
      note "解决：docker compose up -d --force-recreate bot"
      note "（docker compose restart 只是重启进程，**不会**重读 .env）"
    else
      ok "运行中的 bot 容器与 .env 一致"
    fi
  fi
fi

if [ -f docker-compose.yml ]; then
  if docker compose config >/dev/null 2>&1; then
    ok "docker compose config 解析通过"
  else
    bad "docker compose config 解析失败："
    docker compose config 2>&1 | sed 's/^/      /' | head -n 12
  fi
else
  bad "当前目录没有 docker-compose.yml —— 你是不是不在 deploy 仓库根目录？"
  note "本脚本要在 xcollector-deploy 根目录跑。"
fi

ONEBOT_MODE_V=$(env_get ONEBOT_MODE 'client')
EXTRACTOR_V=$(env_get EXTRACTOR 'llm')
GROUP_WHITELIST_V=$(env_get GROUP_WHITELIST '')
echo

# ---------------------------------------------------------------- 端口
echo "■ 宿主机端口"

BACKEND_P=$(env_get BACKEND_HOST_PORT '8000')
BOT_P=$(env_get BOT_HOST_PORT '8082')
ONEBOT_P=$(env_get ONEBOT_HOST_PORT '8081')

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
    note "是别的服务 → 在 .env 里改 $_var 换一个端口，再同步改反向代理"
    note "是遗留的 xcollector 容器 → docker compose down 之后再 up"
    return 1
  fi

  ok "$_name 端口 $_port 空闲"
  return 0
}

check_port "backend" "$BACKEND_P" "BACKEND_HOST_PORT"
check_port "bot HTTP" "$BOT_P" "BOT_HOST_PORT"
if [ "$ONEBOT_MODE_V" = "server" ]; then
  check_port "bot 反向 WS" "$ONEBOT_P" "ONEBOT_HOST_PORT"
else
  note "ONEBOT_MODE=$ONEBOT_MODE_V（正向 WS），$ONEBOT_P 只在 server 模式才需要，跳过"
fi

# 三个端口撞在一起是自己配错了，docker 会报一个很难懂的错
if [ "$BACKEND_P" = "$BOT_P" ] || [ "$BACKEND_P" = "$ONEBOT_P" ] || [ "$BOT_P" = "$ONEBOT_P" ]; then
  bad "三个宿主机端口有重复 —— 每个服务必须不同"
fi
echo

# ---------------------------------------------------------------- 镜像
echo "■ 镜像"

IMAGE_BACKEND_V=$(env_get IMAGE_BACKEND 'ghcr.io/xqy1y4ever/xcollector-backend')
IMAGE_BOT_V=$(env_get IMAGE_BOT 'ghcr.io/xqy1y4ever/xcollector-bot')
VERSION_V=$(env_get VERSION 'latest')

for spec in "backend:$IMAGE_BACKEND_V:$VERSION_V" "bot:$IMAGE_BOT_V:$VERSION_V"; do
  _n=${spec%%:*}; _rest=${spec#*:}
  _img=${_rest%:*}; _tag=${_rest##*:}
  _full="$_img:$_tag"

  case "$_full" in
    *[A-Z]*) bad "$_n 镜像名含大写：$_full"
             note "GHCR 只接受全小写路径，用户名里的 Xqy1y4ever 必须写成 xqy1y4ever" ;;
    *)
      if docker image inspect "$_full" >/dev/null 2>&1; then
        ok "$_n 镜像本地已有：$_full"
      elif docker manifest inspect "$_full" >/dev/null 2>&1; then
        ok "$_n 镜像远端可拉：$_full"
      else
        warn "$_n 镜像拉不到：$_full"
        note "本地没有，远端也查不到。可能还没构建完，或仓库是 private 而你没登录。"
        note "看看 CI 有没有跑成功，或手动试： docker pull $_full"
      fi ;;
  esac
done

PULL_POLICY_V=$(env_get PULL_POLICY 'missing')
if [ "$PULL_POLICY_V" = "missing" ] && [ "$VERSION_V" = "latest" ]; then
  note "PULL_POLICY=missing + VERSION=latest：本地已有旧镜像时**不会**自动升级"
  note "想跟着最新走就设 PULL_POLICY=always，或升级时手动 docker compose pull"
fi
echo

# ---------------------------------------------------------------- 功能开关
echo "■ 功能开关"

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
      note "（LLM_PRIMARY_PROVIDER=deepseek → DEEPSEEK_API_KEY），"
      note "或者直接用 LLM_PRIMARY_API_KEY 指定。"
    fi ;;
  *) bad "EXTRACTOR=$EXTRACTOR_V 不是合法值（只能是 rule / llm / both）" ;;
esac

# 白名单是 **fail-closed** 的：两个都留空 = bot 一条消息都不会处理。
# 这跟「留空就全收」完全相反，不说清楚的话表现出来只是「bot 连上了但什么都不干」。
if [ -z "$GROUP_WHITELIST_V" ]; then
  bad "GROUP_WHITELIST 为空 —— bot 会**忽略所有群的消息**"
  note "白名单是 fail-closed 的：留空不等于「全收」，等于「一个都不收」。"
  note "填上要处理的群：GROUP_WHITELIST=123456789:官方通知群"
else
  ok "GROUP_WHITELIST 已设置"
fi

SENDER_MODE_V=$(env_get SENDER_WHITELIST_MODE 'strict')
if [ "$SENDER_MODE_V" = "off" ]; then
  warn "SENDER_WHITELIST_MODE=off —— 白名单群里**谁发的消息都会被处理**"
  note "官方通知一般只由固定几个人发布。确认这是你要的，否则改成 strict 并配 SENDER_WHITELIST。"
elif [ -z "$(env_get SENDER_WHITELIST '')" ]; then
  bad "SENDER_WHITELIST 为空 —— bot 会**忽略所有发送者的消息**"
  note "填上发布通知的人：SENDER_WHITELIST=10001:张老师"
  note "（如果这个群里谁发的都该收，把 SENDER_WHITELIST_MODE 设成 off —— 那是显式放开。）"
else
  ok "SENDER_WHITELIST 已设置（mode=$SENDER_MODE_V）"
fi

if [ -z "$(env_get COMMAND_WHITELIST '')" ]; then
  ok "COMMAND_WHITELIST 为空 = 谁都不能发指令（安全的默认值）"
else
  ok "COMMAND_WHITELIST 已设置"
fi

DIGEST_ENABLED_V=$(env_get DIGEST_ENABLED 'true')
if [ "$DIGEST_ENABLED_V" = "true" ] && [ -z "$(env_get DIGEST_TARGET_QQ '')" ]; then
  warn "DIGEST_ENABLED=true 但 DIGEST_TARGET_QQ 为空 —— 摘要发不出去"
fi
echo

# ---------------------------------------------------------------- 结论
echo "==================="
if [ "$PROBLEMS" -gt 0 ]; then
  printf '%s必须先处理 %d 个问题%s（另有 %d 条提醒）\n' "$RED" "$PROBLEMS" "$RST" "$WARNINGS"
  echo "处理完再跑一次本脚本，全绿了再 docker compose up -d"
  exit 1
fi

if [ "$WARNINGS" -gt 0 ]; then
  printf '%s可以启动%s，但有 %d 条提醒值得看一眼。\n' "$YEL" "$RST" "$WARNINGS"
else
  printf '%s全部通过。%s\n' "$GRN" "$RST"
fi

echo
echo "接下来："
echo "  docker compose up -d          # 后台启动"
echo "  docker compose logs -f bot    # 看 bot 有没有连上 NapCat"
echo
echo "还没做的话别忘反向代理：/ 指向静态文件，/api/ 指向 127.0.0.1:${BACKEND_P}"
echo "（前缀保留，并且要**原样转发 Authorization 头**）。"
echo "bot 的 127.0.0.1:${BOT_P} **不要**反代到公网 —— 那是运营者的管理接口。"
echo
echo "第一次用要先注册：在 QQ 里给机器人发 /注册，再把验证码拿到网页上完成注册。"
echo
exit 0
