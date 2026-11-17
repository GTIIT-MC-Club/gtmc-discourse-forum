# frozen_string_literal: true

# 导入或更新 GTMC 主题，可重复执行：打包 theme/、导入、设为默认主题、配色跟随系统。
#   - 浅色配色设为 GTMC Light，深色配色设为 GTMC Dark（访客的系统是深色模式时自动用后者）；
#   - 两套配色都允许用户在「界面」偏好里自选。
# 主题已存在时原地更新，不会新建第二个 GTMC；更新不会改动后台里设过的主题设置（如 discord_invite_url）。
#
# 用法（在自有机器上）：脚本在容器里读不到仓库，所以要把 theme/ 目录一起复制进容器，并把容器里的路径作为参数：
#   docker cp theme app:/tmp/gtmc-theme && docker cp infra/discourse/import_theme.rb app:/tmp/ && \
#     docker exec -u discourse -w /var/www/discourse app \
#       bundle exec rails runner /tmp/import_theme.rb /tmp/gtmc-theme
# 本机开发站：在 Discourse 源码目录执行 bin/rails runner <仓库>/infra/discourse/import_theme.rb <仓库>/theme
#
# 执行顺序见 infra/content/admin-setup.md：site_settings.rb → 本脚本 → sidebar.rb → badges.rb → narrative_bot.rb。
# 每次执行都会重新导入一遍主题（导入本身是幂等的，结果相同）。主题改动后重跑即可上线。

require "tmpdir"
require "zip"

THEME_NAME = "GTMC"
LIGHT_COLOR_SCHEME_NAME = "GTMC Light"
DARK_COLOR_SCHEME_NAME = "GTMC Dark"

# 不原样打包的内容：字体的许可和字符表、说明文档只给仓库读者看；icons/ 由 build_icon_sprite 拼成精灵再打包
THEME_DIRECTORY_ENTRIES_NOT_PACKED = %w[fonts icons README.md]
# Discourse 每个主题只认一个图标精灵（lib/svg_sprite.rb 的 icons-sprite），而图标在仓库里一个文件一个，
# 方便单独画、单独改。所以打包时把 icons/*.svg 拼成这一个文件，路径与 about.json 的 icons-sprite 一致。
ICON_SPRITE_ARCHIVE_PATH = "assets/gtmc-icons.svg"
ICON_NAME_PATTERN = /\Agtmc-[a-z0-9-]+\z/
# 导出工具可能写死颜色；一律换成 currentColor，图标才能跟着版块颜色和深浅配色变色
ICON_COLOR_ATTRIBUTES = %w[fill stroke]
# 压缩包文件名只用于核心判断格式，必须以 .zip 结尾
THEME_ARCHIVE_FILENAME = "gtmc-theme.zip"

def theme_directory!
  directory = ARGV.first
  abort "usage: rails runner import_theme.rb <path to the theme/ directory>" if directory.nil?
  unless File.file?(File.join(directory, "about.json"))
    abort "#{directory} is not a directory, or has no about.json"
  end

  directory
end

def packable_files(theme_directory)
  Dir
    .glob("**/*", File::FNM_DOTMATCH, base: theme_directory)
    .reject do |relative_path|
      THEME_DIRECTORY_ENTRIES_NOT_PACKED.include?(relative_path.split("/").first)
    end
    .reject { |relative_path| File.basename(relative_path) == ".DS_Store" }
    .select { |relative_path| File.file?(File.join(theme_directory, relative_path)) }
    .sort
end

# 每个图标文件是一个独立的 SVG（任何绘图工具导出的都行），文件名就是图标名。
# 取根元素的 viewBox 和全部子元素，包成 <symbol id="图标名">；颜色统一成 currentColor。
def build_icon_sprite(icons_directory)
  icon_paths = Dir.glob(File.join(icons_directory, "*.svg")).sort
  abort "no icons found in #{icons_directory}" if icon_paths.empty?

  symbols = icon_paths.map { |icon_path| icon_symbol(icon_path) }
  puts "built icon sprite from #{icon_paths.size} icons"
  %(<svg xmlns="http://www.w3.org/2000/svg">\n#{symbols.join("\n")}\n</svg>\n)
end

def icon_symbol(icon_path)
  icon_name = File.basename(icon_path, ".svg")
  unless icon_name.match?(ICON_NAME_PATTERN)
    abort "icon file #{icon_path}: the name must start with gtmc- and use lowercase letters, digits and -"
  end

  svg = Nokogiri.XML(File.read(icon_path)).root
  abort "icon file #{icon_path} is not an SVG" if svg.nil? || svg.name != "svg"
  view_box = svg["viewBox"] || abort("icon file #{icon_path} has no viewBox")

  svg.traverse do |node|
    next unless node.element?
    ICON_COLOR_ATTRIBUTES.each do |attribute|
      node[attribute] = "currentColor" if node[attribute] && node[attribute] != "none"
    end
  end
  %(<symbol id="#{icon_name}" viewBox="#{view_box}">#{svg.children.map(&:to_xml).join.strip}</symbol>)
end

# about.json 放在压缩包顶层：核心导入时只在「解压后只有一个顶层文件夹」时才会剥掉外层目录，
# 顶层就是主题根时不用依赖这个行为。
def build_theme_archive(theme_directory, archive_path)
  files = packable_files(theme_directory)
  Zip::File.open(archive_path, create: true) do |archive|
    files.each do |relative_path|
      archive.add(relative_path, File.join(theme_directory, relative_path))
    end
    archive.get_output_stream(ICON_SPRITE_ARCHIVE_PATH) do |stream|
      stream.write(build_icon_sprite(File.join(theme_directory, "icons")))
    end
  end
  puts "packed #{files.size} files and the icon sprite from #{theme_directory}"
end

# 传 theme_id 才会更新已有主题；不传则核心每次都新建一个主题
def import_theme(archive_path)
  existing_themes = Theme.where(name: THEME_NAME).to_a
  if existing_themes.size > 1
    abort "found #{existing_themes.size} themes named #{THEME_NAME}; delete the extras in the admin first"
  end

  RemoteTheme.update_zipped_theme(
    archive_path,
    THEME_ARCHIVE_FILENAME,
    theme_id: existing_themes.first&.id,
  )
rescue RemoteTheme::ImportError => error
  abort "theme import failed: #{error.message}"
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
      "color scheme #{name} not found in theme #{THEME_NAME}; check color_schemes in theme/about.json",
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

theme_directory = theme_directory!

theme =
  Dir.mktmpdir("gtmc-theme") do |work_directory|
    archive_path = File.join(work_directory, THEME_ARCHIVE_FILENAME)
    build_theme_archive(theme_directory, archive_path)
    import_theme(archive_path)
  end
puts "imported theme #{theme.name} (id #{theme.id})"

assert_theme_compiled!(theme)

light_scheme = find_color_scheme!(theme, LIGHT_COLOR_SCHEME_NAME)
dark_scheme = find_color_scheme!(theme, DARK_COLOR_SCHEME_NAME)

apply_default_theme(theme)
allow_users_to_select(light_scheme)
allow_users_to_select(dark_scheme)
apply_color_schemes(theme, light_scheme, dark_scheme)
