#!/usr/bin/env sh
# 停掉 bot（或离线客户端）。
#
#     ./stop.sh           # 停 bot
#     ./stop.sh client    # 停离线客户端
#
# 两者都**没有需要保留的本地状态**：
#   - bot 的待确认、/list 编号、摘要发送记录全在后端；
#   - 客户端的状态库（镜像）在源库旁边那个挂载目录里，不在容器里。
# 所以删容器是安全的，重启后不会丢待办、也不会重复推送。

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 2
cd "$SCRIPT_DIR" || exit 2

TARGET=${1:-bot}
case "$TARGET" in
  bot)    NAME=xcollector-bot ;;
  client) NAME=xcollector-client ;;
  *)
    echo "用法： ./stop.sh [bot|client]" >&2
    exit 2
    ;;
esac

if ! docker container inspect "$NAME" >/dev/null 2>&1; then
  echo "没有名为 $NAME 的容器，不用停。"
  exit 0
fi

docker rm -f "$NAME" >/dev/null
echo "已停掉并删除容器 $NAME"
