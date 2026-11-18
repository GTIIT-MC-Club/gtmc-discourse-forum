# frozen_string_literal: true

# 把论坛上的设置导出成 YAML，作为 forum-config/ 目录里的备份（结构和用法见 CONFIGURATION.md）。
# 只读，不改任何东西。由 infra/export-forum-config.sh 调用：
#   rails runner export_config.rb <输出目录>
#
# 输出按名字排序、不含 id 和时间戳，两次导出之间没改设置时文件不变，git diff 只显示真正改过的项。

require "fileutils"
require "yaml"

# 名字里带这些词的设置一律不导出，即使核心没把它标成 secret：备份会提交进公开仓库，分不清就不放
SECRET_SETTING_NAME_PATTERN = /secret|password|token|api_key|private_key|credentials/
GENERATED_FILE_HEADER = "# 由 infra/export-forum-config.sh 从论坛导出，不要手改。回档方法见 CONFIGURATION.md。\n"

def write_yaml(directory, file_name, content)
  path = File.join(directory, file_name)
  File.write(path, GENERATED_FILE_HEADER + content.to_yaml(line_width: -1))
  puts "wrote #{file_name}"
end

def exportable_setting?(setting)
  !setting[:secret] && !setting[:setting].to_s.match?(SECRET_SETTING_NAME_PATTERN)
end

# 格式与核心 rake site_settings:import 读的一样（设置名 => 值），回档时可以直接喂给它。
# 插件的设置也是站点设置，一起在这里。被 DISCOURSE_* 环境变量覆盖的设置是隐藏的，不在这里，它们在 app.yml。
def site_settings
  exportable_names =
    SiteSetting.all_settings.select { |setting| exportable_setting?(setting) }.map { |setting| setting[:setting].to_s }
  SiteSettingsTask.export_to_hash.slice(*exportable_names).sort.to_h
end

def changed_theme_settings(theme)
  theme
    .settings
    .values
    .reject { |setting| setting.value == setting.default }
    .sort_by(&:name)
    .to_h { |setting| [setting.name.to_s, setting.value] }
end

def themes
  Theme
    .order(:name)
    .map do |theme|
      {
        "name" => theme.name,
        "component" => theme.component,
        "default" => theme.default?,
        "user_selectable" => theme.user_selectable,
        "remote_url" => theme.remote_theme&.remote_url,
        "light_color_scheme" => theme.color_scheme&.name,
        "dark_color_scheme" => theme.dark_color_scheme&.name,
        "child_components" => theme.child_themes.order(:name).pluck(:name),
        "settings" => changed_theme_settings(theme),
      }
    end
end

# 色值只导出正在用的配色（默认主题和用户可选主题的浅色、深色配色），其余二十多套核心自带配色只记名字和是否可选，
# 否则这个文件大半是没人改过的核心色值
def color_schemes
  used_scheme_ids =
    Theme
      .where(id: SiteSetting.default_theme_id)
      .or(Theme.where(user_selectable: true))
      .pluck(:color_scheme_id, :dark_color_scheme_id)
      .flatten
      .compact
  ColorScheme
    .includes(:color_scheme_colors, :theme)
    .order(:name)
    .map do |scheme|
      {
        "name" => scheme.name,
        "theme" => scheme.theme&.name,
        "user_selectable" => scheme.user_selectable,
        "colors" =>
          if used_scheme_ids.include?(scheme.id)
            scheme.color_scheme_colors.sort_by(&:name).to_h { |color| [color.name, color.hex] }
          end,
      }.compact
    end
end

def category_permissions(category)
  category
    .category_groups
    .includes(:group)
    .sort_by { |category_group| category_group.group.name }
    .to_h { |category_group| [category_group.group.name, CategoryGroup.permission_types.key(category_group.permission_type).to_s] }
end

def categories
  Category
    .includes(:parent_category, topic: :first_post)
    .order(:position, :name)
    .map do |category|
      {
        "name" => category.name,
        "slug" => category.slug,
        "parent" => category.parent_category&.name,
        "position" => category.position,
        "color" => category.color,
        "text_color" => category.text_color,
        "style_type" => category.style_type,
        "icon" => category.icon,
        "emoji" => category.emoji,
        "description" => category.topic&.first_post&.raw,
        "topic_title_placeholder" => category.topic_title_placeholder,
        "topic_template" => category.topic_template,
        "default_view" => category.default_view,
        "sort_order" => category.sort_order,
        "permissions" => category_permissions(category),
      }
    end
end

def sidebar_sections
  SidebarSection
    .public_sections
    .includes(sidebar_section_links: :linkable)
    .order(:title)
    .map do |section|
      links =
        section
          .sidebar_section_links
          .sort_by(&:position)
          .select { |link| link.linkable.is_a?(SidebarUrl) }
          .map do |link|
            url = link.linkable
            { "name" => url.name, "value" => url.value, "icon" => url.icon, "segment" => url.segment }
          end
      { "title" => section.title, "section_type" => section.section_type, "links" => links }
    end
end

# 核心和插件自带的徽章（system 为 true）由它们自己维护，只记是否启用；自建的徽章导出全部设置
def badges
  Badge
    .includes(:badge_grouping)
    .order(:name)
    .map do |badge|
      next { "name" => badge.name, "enabled" => badge.enabled } if badge.system

      {
        "name" => badge.name,
        "enabled" => badge.enabled,
        "badge_type" => BadgeType.find(badge.badge_type_id).name,
        "grouping" => badge.badge_grouping&.name,
        "icon" => badge.icon,
        "description" => badge.description,
        "long_description" => badge.long_description,
        "allow_title" => badge.allow_title,
        "multiple_grant" => badge.multiple_grant,
        "listable" => badge.listable,
        "auto_revoke" => badge.auto_revoke,
        "target_posts" => badge.target_posts,
        "show_posts" => badge.show_posts,
        "trigger" => badge.trigger,
        "query" => badge.query,
      }.compact
    end
end

GROUP_ATTRIBUTES = %w[
  full_name
  title
  bio_raw
  grant_trust_level
  primary_group
  visibility_level
  members_visibility_level
  mentionable_level
  messageable_level
  public_admission
  public_exit
  allow_membership_requests
  automatic_membership_email_domains
  flair_icon
]

# 只导出群组本身的设置，不导出成员：成员名单是用户数据，不是网站设置
def groups
  Group
    .where(automatic: false)
    .order(:name)
    .map { |group| { "name" => group.name }.merge(group.attributes.slice(*GROUP_ATTRIBUTES)) }
end

def text_overrides
  TranslationOverride
    .order(:locale, :translation_key)
    .map { |override| { "locale" => override.locale, "key" => override.translation_key, "value" => override.value } }
end

USER_FIELD_ATTRIBUTES = %w[description field_type requirement editable show_on_profile show_on_user_card searchable position]

def user_fields
  UserField.order(:position).map { |field| { "name" => field.name }.merge(field.attributes.slice(*USER_FIELD_ATTRIBUTES)) }
end

output_directory = ARGV.fetch(0) { abort "usage: rails runner export_config.rb <output directory>" }
FileUtils.mkdir_p(output_directory)

write_yaml(output_directory, "site_settings.yml", site_settings)
write_yaml(output_directory, "themes.yml", themes)
write_yaml(output_directory, "color_schemes.yml", color_schemes)
write_yaml(output_directory, "categories.yml", categories)
write_yaml(output_directory, "sidebar.yml", sidebar_sections)
write_yaml(output_directory, "badges.yml", badges)
write_yaml(output_directory, "groups.yml", groups)
write_yaml(output_directory, "text_overrides.yml", text_overrides)
write_yaml(output_directory, "user_fields.yml", user_fields)
