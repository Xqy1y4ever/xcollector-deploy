#!/usr/bin/env sh
# 停掉 backend 容器。
#
#     ./stop.sh
#
# **数据不会丢**：SQLite 库与附件都在数据卷里（名字见 .env 的 BACKEND_VOLUME），
# 删容器只是删掉那层可写的容器文件系统。要连数据一起删，看 README「清空重来」。

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 2
cd "$SCRIPT_DIR" || exit 2

NAME=xcollector-backend

if ! docker container inspect "$NAME" >/dev/null 2>&1; then
  echo "没有名为 $NAME 的容器，不用停。"
  exit 0
fi

docker rm -f "$NAME" >/dev/null
echo "已停掉并删除容器 $NAME（数据卷保留）"
