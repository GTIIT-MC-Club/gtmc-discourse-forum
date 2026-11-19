#!/usr/bin/env bash
# 部署论坛：更新容器配置和代码（插件、主题、教程）。论坛设置只在新站上初始化一次，之后归后台管理，
# 本脚本不再覆盖（为什么、怎么备份和回档见 CONFIGURATION.md）。
# 插件和主题不经过本脚本复制：插件由 app.yml 的钩子在重建时克隆，主题由 import_theme.rb 让容器从 GitHub 安装，
# 教程仓库 gtmc-forum-wiki 由本脚本克隆或拉取到本仓库旁边（$WIKI_REPO）再交给 guides.rb。
# 在论坛虚拟机（100 gtmc-forum）上，从仓库检出目录里用 root 执行：
#   sudo infra/deploy-discourse.sh
#   sudo infra/deploy-discourse.sh --rebuild      # 强制重建容器（改 app.yml 之外的容器配置时）
#   sudo infra/deploy-discourse.sh --no-scripts   # 只同步 app.yml 和容器，不跑站点里的脚本
#
# 环境变量：
#   GTMC_APP_TEMPLATE  用哪份容器配置，默认 app.yml；内网阶段（没有域名）用 app.internal.yml
#   GTMC_FORCE_HTTPS   初始化新站时传给 site_settings.rb，默认 true；没有 TLS 的阶段必须传 false，
#                      否则全站 301 到 https:// 而那个端口上没有 TLS。站点初始化之后改到后台去改
#   GTMC_FORUM_HOST    覆盖配置里的 DISCOURSE_HOSTNAME。域名属于部署而不属于代码（PLAN 第 1 节），
#                      临时的测试域名尤其不该提交进仓库，所以在这里传入
#   GTMC_SMTP_ENV_FILE 发信配置，默认 /etc/gtmc/smtp.env（格式见 infra/README.md「发信」）。
#                      文件存在就把里面的 DISCOURSE_* 写进容器配置并去掉 DISCOURSE_DISABLE_EMAILS；
#                      不存在就照模板原样，内网配置下即不发信。SMTP 密码因此不进仓库
# 例：
#   sudo GTMC_APP_TEMPLATE=app.internal.yml GTMC_FORCE_HTTPS=false infra/deploy-discourse.sh
#   sudo GTMC_APP_TEMPLATE=app.internal.yml GTMC_FORUM_HOST=tempforum.example.com infra/deploy-discourse.sh
#
# 可重复执行：app.yml 内容没变就不重建容器（重建有停机）。

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WIKI_REPO="$(dirname "$REPO")/gtmc-forum-wiki"
WIKI_REPOSITORY_URL="https://github.com/GTIIT-MC-Club/gtmc-forum-wiki.git"
DISCOURSE_DIR="${DISCOURSE_DIR:-/var/discourse}"
CONTAINER="${CONTAINER:-app}"
APP_TEMPLATE="$REPO/infra/discourse/${GTMC_APP_TEMPLATE:-app.yml}"
FORCE_HTTPS="${GTMC_FORCE_HTTPS:-true}"
FORUM_HOST="${GTMC_FORUM_HOST:-}"
SMTP_ENV_FILE="${GTMC_SMTP_ENV_FILE:-/etc/gtmc/smtp.env}"

DEPLOY_ARGUMENTS=("$@")
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
# 拉到了新提交就用新版本的本脚本从头再跑一遍：bash 已经读进内存的函数还是旧的，接着跑会按旧逻辑部署。
sync_repository() {
  if [ ! -d "$REPO/.git" ] || [ -n "${GTMC_DEPLOY_PULLED:-}" ]; then
    return
  fi
  local owner previous_head
  owner="$(stat -c %U "$REPO")"
  previous_head="$(sudo -u "$owner" git -C "$REPO" rev-parse HEAD)"
  echo "== 以 $owner 的身份同步仓库 $REPO"
  sudo -u "$owner" git -C "$REPO" pull --ff-only
  if [ "$(sudo -u "$owner" git -C "$REPO" rev-parse HEAD)" != "$previous_head" ]; then
    echo "== 仓库有更新，用新版本的部署脚本重新开始"
    GTMC_DEPLOY_PULLED=1 exec "$REPO/infra/deploy-discourse.sh" "${DEPLOY_ARGUMENTS[@]}"
  fi
}

# 教程仓库和本仓库同一个属主，理由同 sync_repository。
sync_wiki_repository() {
  local owner
  owner="$(stat -c %U "$REPO")"
  if [ -d "$WIKI_REPO/.git" ]; then
    echo "== 以 $owner 的身份拉取教程仓库 $WIKI_REPO"
    sudo -u "$owner" git -C "$WIKI_REPO" pull --ff-only
  else
    echo "== 以 $owner 的身份克隆教程仓库到 $WIKI_REPO"
    sudo -u "$owner" git clone "$WIKI_REPOSITORY_URL" "$WIKI_REPO"
  fi
}

pick_web_hostname() {
  sed -n 's/^  DISCOURSE_HOSTNAME:[[:space:]]*//p' "$1"
}

# 主机名可能来自环境变量：只在显式传了 GTMC_FORUM_HOST 时改，其余原样。
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

# 值一律写成 YAML 单引号字符串（内部的单引号写两遍），密码里有 # : 空格等字符也不会被 YAML 误解。
merge_smtp_env() {
  local rendered="$1" env_lines="$2" line key value count=0
  if [ ! -f "$SMTP_ENV_FILE" ]; then
    echo "== 没有 ${SMTP_ENV_FILE}，容器配置里不加发信设置"
    return
  fi
  : >"$env_lines"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '' | '#'*) continue ;; esac
    key="${line%%=*}"
    value="${line#*=}"
    if ! printf '%s' "$key" | grep -Eq '^DISCOURSE_[A-Z0-9_]+$' || [ "$key" = "$line" ]; then
      echo "$SMTP_ENV_FILE 里有一行不是 DISCOURSE_XXX=值 的格式（键：${key}），停止。" >&2
      exit 1
    fi
    # 不用 ${value//\'/...}：替换串里引号的处理在 bash 各版本间不一致
    printf "  %s: '%s'\n" "$key" "$(printf '%s' "$value" | sed "s/'/''/g")" >>"$env_lines"
    count=$((count + 1))
  done <"$SMTP_ENV_FILE"
  grep -v '^  DISCOURSE_DISABLE_EMAILS:' "$rendered" | sed "/^env:\$/r $env_lines" >"$rendered.merged"
  mv "$rendered.merged" "$rendered"
  echo "== 发信设置来自 ${SMTP_ENV_FILE}（$count 项），已打开邮件"
}

install_app_config() {
  local hostname workdir rendered
  workdir="$(mktemp -d)"
  # shellcheck disable=SC2064  # 立即展开：退出时 workdir 这个局部变量已经不在了
  trap "rm -rf '$workdir'" EXIT
  rendered="$workdir/app.yml"
  render_app_config "$rendered"
  merge_smtp_env "$rendered" "$workdir/smtp-env.yml"
  hostname="$(pick_web_hostname "$rendered")"
  if grep -q 'CHANGEME' "$rendered"; then
    echo "$APP_TEMPLATE 里还有 CHANGEME 占位符，填好再部署（内网阶段用 GTMC_APP_TEMPLATE=app.internal.yml）。" >&2
    exit 1
  fi
  if [ -z "$hostname" ]; then
    echo "在 $APP_TEMPLATE 里找不到 DISCOURSE_HOSTNAME，停止。" >&2
    exit 1
  fi
  echo "== 容器配置来自 ${APP_TEMPLATE}（DISCOURSE_HOSTNAME=${hostname}）"

  if [ -f "$DISCOURSE_DIR/containers/app.yml" ] && cmp -s "$rendered" "$DISCOURSE_DIR/containers/app.yml"; then
    echo "   内容和已装的一致，不需要重建"
    needs_rebuild=0
  else
    # 600：渲染后的文件里可能有 SMTP 密码
    install -o root -g root -m 600 "$rendered" "$DISCOURSE_DIR/containers/app.yml"
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

# 初始化标记存在论坛数据库里（PluginStore），跟着数据走：从备份恢复的站点也带着它，不会被重新初始化。
# 读不到明确的结果就停下，不猜：猜错了会把后台改过的设置全部覆盖掉。
site_initialization_state() {
  docker exec -u discourse -w /var/www/discourse "$CONTAINER" bundle exec rails runner \
    'print(PluginStore.get("gtmc_infra", "initialized_at") ? "initialized" : "fresh")' | tail -n 1
}

mark_site_initialized() {
  docker exec -u discourse -w /var/www/discourse "$CONTAINER" bundle exec rails runner \
    'PluginStore.set("gtmc_infra", "initialized_at", Time.now.utc.iso8601); puts "marked the site as initialized"'
}

# 新站：按 site_settings → 主题 → 侧边栏 → 徽章 → 小火把的顺序初始化，后一个依赖前一个的结果
initialize_site() {
  docker cp "$REPO/infra/discourse/site_settings.rb" "$CONTAINER:/tmp/"
  run_script "初始化：站点设置、版块、信任等级门槛" /tmp/site_settings.rb

  install_or_update_theme

  docker cp "$REPO/infra/discourse/sidebar.rb" "$CONTAINER:/tmp/"
  run_script "初始化：侧边栏、版块顺序和图标、页脚" /tmp/sidebar.rb

  docker cp "$REPO/infra/discourse/badges.rb" "$CONTAINER:/tmp/"
  run_script "初始化：社团徽章" /tmp/badges.rb

  run_script "初始化：引导机器人小火把" /tmp/gtmc-infra/discourse/narrative_bot.rb

  mark_site_initialized
}

# 主题代码从 GitHub 更新；默认主题和配色只在第一次安装时设置（见 import_theme.rb）
install_or_update_theme() {
  docker cp "$REPO/infra/discourse/import_theme.rb" "$CONTAINER:/tmp/"
  run_script "从 GitHub 安装或更新 GTMC 主题" /tmp/import_theme.rb
}

apply_site_configuration() {
  sync_wiki_repository
  copy_into_container "$REPO/infra" /tmp/gtmc-infra

  local state
  state="$(site_initialization_state)"
  case "$state" in
    fresh) initialize_site ;;
    initialized)
      echo "== 站点已初始化过，论坛设置归后台管理，跳过初始化脚本"
      install_or_update_theme
      ;;
    *)
      echo "读不出站点的初始化状态（收到：$state），停止部署，没有改动任何设置。" >&2
      exit 1
      ;;
  esac

  copy_into_container "$WIKI_REPO" /tmp/gtmc-forum-wiki
  run_script "新手教程（从 gtmc-forum-wiki 同步到「新人指南」）" /tmp/gtmc-infra/discourse/guides.rb /tmp/gtmc-forum-wiki
}

require_root "$@"
sync_repository
install_app_config
rebuild_container

if [ "$run_scripts" -eq 1 ]; then
  apply_site_configuration
  cat <<'DONE'

== 完成
新站初始化之后还要手工做的事见 infra/content/admin-setup.md（上传 Logo 和图标、发欢迎帖）。
改了后台设置，记得用 infra/export-forum-config.sh 备份到仓库（见 CONFIGURATION.md）。
DONE
fi
