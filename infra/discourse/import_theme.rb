# frozen_string_literal: true

# 从 Git 安装或更新 GTMC 主题，可重复执行：安装或更新、设为默认主题、配色跟随系统。
#   - 主题来自 gtmc-forum-theme 仓库的默认分支，用核心的远程主题（RemoteTheme）安装，
#     后台「外观 → 主题」能看到版本、检查更新；
#   - 浅色配色设为 GTMC Light，深色配色设为 GTMC Dark（访客的系统是深色模式时自动用后者）；
#   - 两套配色都允许用户在「界面」偏好里自选。
# 主题已存在时原地更新，不会新建第二个 GTMC；更新不会改动后台里设过的主题设置（如 discord_invite_url）。
# 以前用压缩包导入的 GTMC 主题会原地改成远程主题，id 和主题设置都不变。
#
# 用法（在论坛虚拟机上；容器要能连上 github.com，核心在容器里执行 git clone）：
#   docker cp infra/discourse/import_theme.rb app:/tmp/ && \
#     docker exec -u discourse -w /var/www/discourse app bundle exec rails runner /tmp/import_theme.rb
# 本机开发站：在 Discourse 源码目录执行 bin/rails runner <仓库>/infra/discourse/import_theme.rb
#
# 执行顺序见 infra/content/admin-setup.md：site_settings.rb → 本脚本 → sidebar.rb → badges.rb → narrative_bot.rb。
# 每次执行都会从 GitHub 重新拉一遍主题（导入本身是幂等的，结果相同）。主题合并到 main 后重跑即可上线。

THEME_NAME = "GTMC"
# 写成核心存进 remote_themes.remote_url 的样子（GitUrl.normalize 给 GitHub 地址补 .git），才能直接比较
THEME_REPOSITORY_URL = "https://github.com/GTIIT-MC-Club/gtmc-forum-theme.git"
LIGHT_COLOR_SCHEME_NAME = "GTMC Light"
DARK_COLOR_SCHEME_NAME = "GTMC Dark"

def existing_gtmc_theme
  themes = Theme.includes(:remote_theme).where(name: THEME_NAME).to_a
  if themes.size > 1
    abort "found #{themes.size} themes named #{THEME_NAME}; delete the extras in the admin first"
  end

  themes.first
end

def install_theme
  theme = RemoteTheme.import_theme(THEME_REPOSITORY_URL, Discourse.system_user)
  puts "installed theme #{theme.name} (id #{theme.id}) from #{THEME_REPOSITORY_URL}"
  theme
end

# 压缩包导入的主题可能没有 RemoteTheme 记录，也可能有一条 remote_url 为空的。两种都在原主题上补上仓库地址
# 再从远程更新，和核心后台「更换来源」（Admin::ThemesController#update_source）是同一个做法：
# 主题 id 不变，所以 theme_settings 里的值、默认主题、用户选的主题都保留。
# 放进事务：克隆或导入失败时连仓库地址一起回滚，主题仍是原来的压缩包版本。
def convert_to_remote_theme(theme)
  remote_theme = theme.remote_theme || theme.build_remote_theme
  remote_theme.transaction do
    remote_theme.remote_url = THEME_REPOSITORY_URL
    remote_theme.branch = nil
    remote_theme.update_from_remote(already_in_transaction: true, raise_on_import_error: true)
    theme.save!
  end
  puts "converted theme #{theme.name} (id #{theme.id}) to a remote theme from #{THEME_REPOSITORY_URL}"
end

# 不传 raise_on_import_error 时核心把克隆失败记在 last_error_text 里、照常返回，这里要它直接报错
def update_remote_theme(theme)
  remote_theme = theme.remote_theme
  previous_version = remote_theme.local_version
  remote_theme.update_from_remote(raise_on_import_error: true)
  if remote_theme.local_version == previous_version
    puts "theme #{theme.name} is up to date at #{previous_version}"
  else
    puts "updated theme #{theme.name} from #{previous_version} to #{remote_theme.local_version}"
  end
end

def install_or_update_theme
  theme = existing_gtmc_theme
  return install_theme if theme.nil?

  remote_url = theme.remote_theme&.remote_url
  if remote_url.blank?
    convert_to_remote_theme(theme)
  elsif remote_url == THEME_REPOSITORY_URL
    update_remote_theme(theme)
  else
    # 别的仓库装的同名主题不是我们能判断的情况，分不清就不动
    abort "theme #{THEME_NAME} (id #{theme.id}) is installed from #{remote_url}, " \
            "not #{THEME_REPOSITORY_URL}; change its source in the admin or delete it first"
  end
  theme
rescue RemoteTheme::ImportError => error
  abort "theme import from #{THEME_REPOSITORY_URL} failed: #{error.message}"
end

# 样式或模板编译失败时核心只在字段上记一条错误、主题照常保存，页面上悄悄失效。这里让它响起来。
def assert_theme_compiled!(theme)
  theme.reload.theme_fields.each(&:ensure_baked!)
  broken_fields = theme.theme_fields.reload.select { |field| field.error.present? }
  return if broken_fields.empty?

  details = broken_fields.map { |field| "#{field.target_name}/#{field.name}: #{field.error}" }
  abort "theme fields failed to compile:\n#{details.join("\n")}"
end

def find_color_scheme!(theme, name)
  # 核心给每个主题配色另存一份 remote_copy，默认作用域已把它排除，这里取的是主题自己的那份
  ColorScheme.find_by(theme_id: theme.id, name: name) ||
    abort(
      "color scheme #{name} not found in theme #{THEME_NAME}; check color_schemes in about.json of #{THEME_REPOSITORY_URL}",
    )
end

def apply_default_theme(theme)
  if theme.default?
    puts "theme #{theme.name} is already the default"
    return
  end

  theme.set_default!
  puts "set theme #{theme.name} (id #{theme.id}) as the default theme"
end

def allow_users_to_select(color_scheme)
  if color_scheme.user_selectable
    puts "color scheme #{color_scheme.name} is already user selectable"
    return
  end

  color_scheme.update!(user_selectable: true)
  puts "made color scheme #{color_scheme.name} user selectable"
end

# 新建主题时核心只会把 about.json 里排第一的配色设为浅色配色、深色配色留空，所以导入后必须显式设两个。
# 已有主题再次导入时核心不碰这两个字段，管理员在后台改过的话，这里也会改回来。
def apply_color_schemes(theme, light_scheme, dark_scheme)
  if theme.color_scheme_id == light_scheme.id && theme.dark_color_scheme_id == dark_scheme.id
    puts "theme color schemes are up to date"
    return
  end

  theme.update!(color_scheme_id: light_scheme.id, dark_color_scheme_id: dark_scheme.id)
  puts "set theme color schemes: light = #{light_scheme.name}, dark = #{dark_scheme.name}"
end

theme = install_or_update_theme

assert_theme_compiled!(theme)

light_scheme = find_color_scheme!(theme, LIGHT_COLOR_SCHEME_NAME)
dark_scheme = find_color_scheme!(theme, DARK_COLOR_SCHEME_NAME)

apply_default_theme(theme)
allow_users_to_select(light_scheme)
allow_users_to_select(dark_scheme)
apply_color_schemes(theme, light_scheme, dark_scheme)
