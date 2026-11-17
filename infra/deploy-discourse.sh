#!/usr/bin/env bash
# 一键把本仓库里的 Discourse 配置部署到论坛虚拟机的 Discourse 容器。
# 在论坛虚拟机（100 gtmc-forum）上，从仓库检出目录里用 root 执行：
#   sudo infra/deploy-discourse.sh
#   sudo infra/deploy-discourse.sh --rebuild      # 强制重建容器（改 app.yml 之外的容器配置时）
#   sudo infra/deploy-discourse.sh --no-scripts   # 只同步 app.yml 和容器，不动站点设置
#
# 环境变量：
#   GTMC_APP_TEMPLATE  用哪份容器配置，默认 app.yml；内网阶段（没有域名）用 app.internal.yml
#   GTMC_FORCE_HTTPS   传给 site_settings.rb，默认 true；没有 TLS 的阶段必须传 false，
#                      否则全站 301 到 https:// 而那个端口上没有 TLS
#   GTMC_FORUM_HOST    覆盖配置里的 DISCOURSE_HOSTNAME。域名属于部署而不属于代码（PLAN 第 1 节），
#                      临时的测试域名尤其不该提交进仓库，所以在这里传入
# 例：
#   sudo GTMC_APP_TEMPLATE=app.internal.yml GTMC_FORCE_HTTPS=false infra/deploy-discourse.sh
#   sudo GTMC_APP_TEMPLATE=app.internal.yml GTMC_FORUM_HOST=tempforum.example.com infra/deploy-discourse.sh
#
# 可重复执行：app.yml 内容没变就不重建容器（重建有停机），站点脚本本身是幂等的。
# 顺序依赖见 infra/content/admin-setup.md：站点设置 → 主题 → 侧边栏 → 徽章 → 引导机器人，
# 后一个脚本依赖前一个的结果，缺了会自己报错退出。

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISCOURSE_DIR="${DISCOURSE_DIR:-/var/discourse}"
CONTAINER="${CONTAINER:-app}"
APP_TEMPLATE="$REPO/infra/discourse/${GTMC_APP_TEMPLATE:-app.yml}"
FORCE_HTTPS="${GTMC_FORCE_HTTPS:-true}"
FORUM_HOST="${GTMC_FORUM_HOST:-}"

force_rebuild=0
run_scripts=1
needs_rebuild=0
for argument in "$@"; do
  case "$argument" in
    --rebuild) force_rebuild=1 ;;
    --no-scripts) run_scripts=0 ;;
    *) echo "未知参数：$argument" >&2; exit 2 ;;
  esac
done

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "要用 root 执行：sudo $0 $*" >&2
    exit 1
  fi
}

# 仓库属主是普通用户、脚本用 root 跑。以 root 执行 git pull 会在 .git 里留下 root 的文件，
# 之后属主自己 pull 就报权限错误，所以切回属主身份去拉。
sync_repository() {
  if [ ! -d "$REPO/.git" ]; then
    return
  fi
  local owner
  owner="$(stat -c %U "$REPO")"
  echo "== 以 $owner 的身份同步仓库 $REPO"
  sudo -u "$owner" git -C "$REPO" pull --ff-only
}

pick_web_hostname() {
  sed -n 's/^  DISCOURSE_HOSTNAME:[[:space:]]*//p' "$1"
}

# 把模板写成最终的 app.yml：只在传了 GTMC_FORUM_HOST 时替换主机名那一行，其余原样。
render_app_config() {
  local rendered="$1"
  if [ -z "$FORUM_HOST" ]; then
    cp "$APP_TEMPLATE" "$rendered"
    return
  fi
  if ! printf '%s' "$FORUM_HOST" | grep -Eq '^[A-Za-z0-9.-]+$'; then
    echo "GTMC_FORUM_HOST 只能是主机名（字母、数字、点、连字符），收到：$FORUM_HOST" >&2
    exit 1
  fi
  sed "s/^  DISCOURSE_HOSTNAME:.*/  DISCOURSE_HOSTNAME: $FORUM_HOST/" "$APP_TEMPLATE" >"$rendered"
}

install_app_config() {
  local hostname rendered
  rendered="$(mktemp)"
  # shellcheck disable=SC2064  # 立即展开：退出时 rendered 这个局部变量已经不在了
  trap "rm -f '$rendered'" EXIT
  render_app_config "$rendered"
  hostname="$(pick_web_hostname "$rendered")"
  if grep -q 'CHANGEME' "$rendered"; then
    echo "$APP_TEMPLATE 里还有 CHANGEME 占位符，填好再部署（内网阶段用 GTMC_APP_TEMPLATE=app.internal.yml）。" >&2
    exit 1
  fi
  if [ -z "$hostname" ]; then
    echo "在 $APP_TEMPLATE 里找不到 DISCOURSE_HOSTNAME，停止。" >&2
    exit 1
  fi
  echo "== 容器配置来自 $APP_TEMPLATE（DISCOURSE_HOSTNAME=$hostname）"

  if [ -f "$DISCOURSE_DIR/containers/app.yml" ] && cmp -s "$rendered" "$DISCOURSE_DIR/containers/app.yml"; then
    echo "   内容和已装的一致，不需要重建"
    needs_rebuild=0
  else
    install -o root -g root -m 644 "$rendered" "$DISCOURSE_DIR/containers/app.yml"
    echo "   已更新 $DISCOURSE_DIR/containers/app.yml"
    needs_rebuild=1
  fi
}

container_running() {
  [ -n "$(docker ps -q --filter "name=^${CONTAINER}$")" ]
}

rebuild_container() {
  if [ "$needs_rebuild" -eq 0 ] && [ "$force_rebuild" -eq 0 ] && container_running; then
    echo "== 容器 $CONTAINER 在跑，跳过重建"
    return
  fi
  echo "== 重建容器（几分钟，期间论坛不可用）"
  ( cd "$DISCOURSE_DIR" && ./launcher rebuild "$CONTAINER" )
}

# docker cp 一个目录到已存在的位置会把它套一层，所以先清掉上一次的副本。
copy_into_container() {
  local source="$1" target="$2"
  docker exec "$CONTAINER" rm -rf "$target"
  docker cp "$source" "$CONTAINER:$target"
}

run_script() {
  local description="$1" path="$2"
  shift 2
  echo "== $description"
  docker exec -e "GTMC_FORCE_HTTPS=$FORCE_HTTPS" -u discourse -w /var/www/discourse \
    "$CONTAINER" bundle exec rails runner "$path" "$@"
}

apply_site_configuration() {
  docker cp "$REPO/infra/discourse/site_settings.rb" "$CONTAINER:/tmp/"
  run_script "站点设置、版块、信任等级门槛" /tmp/site_settings.rb

  copy_into_container "$REPO/theme" /tmp/gtmc-theme
  docker cp "$REPO/infra/discourse/import_theme.rb" "$CONTAINER:/tmp/"
  run_script "导入 GTMC 主题和两套配色" /tmp/import_theme.rb /tmp/gtmc-theme

  docker cp "$REPO/infra/discourse/sidebar.rb" "$CONTAINER:/tmp/"
  run_script "侧边栏、版块顺序和图标、页脚" /tmp/sidebar.rb

  docker cp "$REPO/infra/discourse/badges.rb" "$CONTAINER:/tmp/"
  run_script "社团徽章" /tmp/badges.rb

  copy_into_container "$REPO/infra" /tmp/gtmc-infra
  run_script "引导机器人小火把" /tmp/gtmc-infra/discourse/narrative_bot.rb
}

require_root "$@"
sync_repository
install_app_config
rebuild_container

if [ "$run_scripts" -eq 1 ]; then
  apply_site_configuration
  cat <<'DONE'

== 完成
还剩下脚本不管的手工步骤（见 infra/content/admin-setup.md）：
  1. 后台上传 Logo：设置 → 品牌 → Logo，用 design/brand/gtmc-logo-3x.png
  2. 在「公告」发两篇置顶帖后重跑一次本脚本，侧边栏和机器人结尾的链接才会指向它们
DONE
fi
