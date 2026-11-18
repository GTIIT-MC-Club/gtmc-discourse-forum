#!/usr/bin/env bash
# 把论坛上的设置导出到本仓库的 forum-config/，作为备份（目录结构和回档方法见 CONFIGURATION.md）。
# 只读论坛，不改任何设置。在自己电脑上的仓库检出里执行（推送 GitHub 用的是你自己的权限），
# 参数是论坛虚拟机的 SSH 地址，那个用户要在 docker 组里：
#   infra/export-forum-config.sh gtmc@gtmc-forum
# 导出后自己看一遍 git diff，确认都是有意的改动，再提交、推送。

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "用法：$0 <论坛虚拟机的 SSH 地址>，例如 $0 gtmc@gtmc-forum" >&2
  exit 2
fi

FORUM_SSH_HOST="$1"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIRECTORY="$REPO/forum-config"
CONTAINER="${CONTAINER:-app}"
# 脚本和导出结果都放在容器里的一个专用目录，每次先清空。全程用 discourse 用户：
# /tmp 开了 protected_regular，root 不能往别的用户在 /tmp 里留下的同名文件里写
CONTAINER_WORK_DIRECTORY=/tmp/gtmc-forum-config-export
CONTAINER_SCRIPT="$CONTAINER_WORK_DIRECTORY/export_config.rb"
CONTAINER_OUTPUT_DIRECTORY="$CONTAINER_WORK_DIRECTORY/forum-config"
CONTAINER_EXEC="docker exec -i -u discourse -w /var/www/discourse $CONTAINER"

echo "== 在 $FORUM_SSH_HOST 的容器 $CONTAINER 里导出论坛设置"
ssh "$FORUM_SSH_HOST" "$CONTAINER_EXEC sh -c 'rm -rf $CONTAINER_WORK_DIRECTORY && mkdir $CONTAINER_WORK_DIRECTORY && cat > $CONTAINER_SCRIPT'" \
  <"$REPO/infra/discourse/export_config.rb"
ssh "$FORUM_SSH_HOST" "$CONTAINER_EXEC bundle exec rails runner $CONTAINER_SCRIPT $CONTAINER_OUTPUT_DIRECTORY"

# 整个目录换成这次导出的结果：论坛上删掉的东西，备份里也要跟着消失。
# 单独一次 ssh 只传 tar 数据，不和上面 rails 的输出混在一起
rm -rf "$OUTPUT_DIRECTORY"
mkdir -p "$OUTPUT_DIRECTORY"
ssh "$FORUM_SSH_HOST" "$CONTAINER_EXEC tar -C $CONTAINER_OUTPUT_DIRECTORY -cf - ." |
  tar -C "$OUTPUT_DIRECTORY" -xf -

echo
echo "== 导出完成。和上一次备份相比改了这些文件："
git -C "$REPO" status --short -- forum-config
cat <<'NEXT'

用 git diff forum-config 逐项确认，再提交并推送：
  git add forum-config && git commit -m "chore(config): back up forum settings" && git push
NEXT
