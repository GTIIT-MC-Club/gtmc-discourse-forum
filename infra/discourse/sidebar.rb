# frozen_string_literal: true

# 新站的侧边栏与版块外观：版块顺序和图标、全站默认侧边栏版块、「社区」区的链接、
# 删除核心自带的 General 和 Site Feedback 版块、把页脚的站内链接写进 GTMC 主题的设置。
# 只在新站初始化时执行一次（infra/deploy-discourse.sh 按数据库里的初始化标记判断），之后这些设置归后台管理，
# 再部署不会覆盖；要备份或回档见 CONFIGURATION.md。
#
# 必须在下面两件事之后执行，缺了会直接报错退出：
#   1. infra/discourse/site_settings.rb 已执行（版块由它创建，这里按名字查找）；
#   2. GTMC 主题已导入（图标来自主题的图标精灵，页脚链接写进主题设置）。
# 所以单独成一个文件，而不是追加进 site_settings.rb：那个脚本要在导入主题前就能执行。
#
# 由 infra/deploy-discourse.sh 调用。
#
# 还会把「公告」版块写进 discourse-gtmc 插件的 gtmc_announcement_category（右栏公告面板读它），
# 所以插件也要已安装。
#

THEME_NAME = "GTMC"

# 顺序即侧边栏和版块列表里的顺序。图标来自 gtmc-forum-theme 的 icons/，见那个仓库 README.md 的「图标」。
CATEGORY_ICONS = [
  %w[公告 gtmc-sign],
  %w[新人指南 gtmc-compass],
  %w[活动 gtmc-cake],
  %w[建筑展示 gtmc-bricks],
  %w[技术开发 gtmc-gear],
  %w[资源分享 gtmc-chest],
  %w[白名单与申诉 gtmc-scroll],
  %w[水吧 gtmc-bucket],
  %w[老玩家俱乐部 gtmc-crown],
]

ANNOUNCEMENT_CATEGORY_NAME = "公告"
APPEAL_CATEGORY_NAME = "白名单与申诉"
NEWCOMER_GUIDE_CATEGORY_NAME = "新人指南"

# 核心自带、本站不用的版块，按核心记录它们的站点设置查找，不按名字（名字随安装时的语言变化）。
# Site Feedback 每次 rebuild 时都会被核心的种子数据重置权限（seed_data/categories.rb 的 force_permissions），
# 改权限藏起来留不住，所以删除。删除后核心不会再建：种子数据只在站点还没有真人用户时创建版块。
# Uncategorized 删不掉（核心禁止），它靠 allow_uncategorized_topics 为 false（核心默认）
# 和不进默认侧边栏来隐藏，这里不动它。
SEEDED_CATEGORY_SETTINGS_TO_DELETE = %w[general_category_id meta_category_id]

def find_category!(name)
  Category.find_by(name: name) ||
    abort("category #{name} not found; run infra/discourse/site_settings.rb first")
end

# 「社区」区（核心的 section_type community）。segment primary 直接显示，secondary 收在「更多」里。
# /latest、/badges 等是核心认识的路径，核心会按路径换成自己的链接实现（处理权限、未读数等）；
# 名字用核心的英文名时，核心会按界面语言翻译（Badges → 徽章），所以这里只在核心没有合适译名时写中文。
# 审核、管理只对管理人员显示（核心按权限判断）。
# 核心默认还有 FAQ 和 Filter：FAQ 和置顶的「欢迎与社区规则」重复，Filter 是高级筛选，新人用不上，都不放。
# 「新人指南」是版块，已在上面的版块区里，这里不再放一个同名链接。
def community_links
  [
    { name: "最新话题", value: "/latest", icon: "gtmc-layers", segment: "primary" },
    { name: "Badges", value: "/badges", icon: "gtmc-medal", segment: "primary" },
    { name: "Users", value: "/u", icon: "gtmc-players", segment: "primary" },
    { name: "Review", value: "/review", icon: "gtmc-magnifier", segment: "primary" },
    { name: "Admin", value: "/admin", icon: "gtmc-hammer", segment: "primary" },
    { name: "My posts", value: "/my/activity", icon: "gtmc-quill", segment: "secondary" },
    { name: "My messages", value: "/my/messages", icon: "gtmc-envelope", segment: "secondary" },
    { name: "Invite", value: "/new-invite", icon: "gtmc-door", segment: "secondary" },
    { name: "About", value: "/about", icon: "gtmc-info", segment: "secondary" },
    { name: "Groups", value: "/g", icon: "gtmc-banner", segment: "secondary" },
  ]
end

def gtmc_theme!
  Theme.find_by(name: THEME_NAME) ||
    abort("theme #{THEME_NAME} not found; run infra/discourse/import_theme.rb first")
end

def assert_icons_in_sprite!(theme, icon_names)
  sprite_icons = SvgSprite.custom_svgs(theme.id).keys
  missing_icons = icon_names - sprite_icons
  return if missing_icons.empty?

  abort "icons missing from the #{THEME_NAME} theme sprite: #{missing_icons.join(", ")}; add them to icons/ in gtmc-forum-theme, rebuild its sprite and rerun import_theme.rb"
end

def apply_category_style(category, position, icon)
  wanted = { position: position, style_type: "icon", icon: icon }
  if wanted.all? { |attribute, value| category.public_send(attribute) == value }
    puts "category #{category.name} style is up to date"
    return
  end

  category.update!(wanted)
  puts "updated category #{category.name}: position #{position}, icon #{icon}"
end

# 本站版块排在最前，其余顶级版块（Staff、Uncategorized、以后在后台新建的）按原有相对顺序排在后面
def apply_category_order(gtmc_categories)
  CATEGORY_ICONS.each_with_index do |(_name, icon), position|
    apply_category_style(gtmc_categories[position], position, icon)
  end

  other_categories =
    Category
      .where(parent_category_id: nil)
      .where.not(id: gtmc_categories.map(&:id))
      .order(:position, :id)
  other_categories.each.with_index(gtmc_categories.size) do |category, position|
    next if category.position == position

    category.update!(position: position)
    puts "moved category #{category.name} to position #{position}"
  end
end

def delete_seeded_category(setting_name)
  category = Category.find_by(id: SiteSetting.get(setting_name))
  if category.nil?
    puts "seeded category #{setting_name} already removed"
    return
  end

  # 核心的欢迎帖（Welcome to …）是英文占位内容，本站用自己写的置顶帖（infra/content/welcome.md）代替。
  # 软删除，管理员仍可在后台恢复；welcome_topic_id 保持原值，核心就不会重新生成它。
  welcome_topic = Topic.find_by(id: SiteSetting.welcome_topic_id, category_id: category.id)
  user_topic_count =
    Topic.where(category_id: category.id).where.not(id: [category.topic_id, welcome_topic&.id]).count
  if user_topic_count > 0
    # 有真人发的帖子就不删，免得连带丢内容。打印出来后由管理员在后台把帖子移走、再删掉这个版块。
    puts "kept category #{category.name}: it still has #{user_topic_count} topics; move them out and re-run"
    return
  end

  if welcome_topic
    PostDestroyer.new(
      Discourse.system_user,
      welcome_topic.first_post,
      context: "replaced by the GTMC welcome topic (infra/discourse/sidebar.rb)",
    ).destroy
    puts "trashed core welcome topic #{welcome_topic.id}"
  end
  # 删除后核心的 after_destroy 会把指向它的站点设置清空（例如 default_composer_category 指向 General 时）
  category.destroy!
  puts "deleted seeded category #{category.name}"
end

# 右栏「公告」面板（discourse-gtmc）按版块 id 读，版块改名或重建后 id 会变，所以每次按名字重新写一遍。
def apply_announcement_panel_category(announcement_category)
  new_value = announcement_category.id.to_s
  if SiteSetting.gtmc_announcement_category.to_s == new_value
    puts "gtmc_announcement_category is up to date"
    return
  end

  SiteSetting.set(:gtmc_announcement_category, new_value)
  puts "set gtmc_announcement_category = #{new_value}"
end

# 已有用户的侧边栏版块是注册时按当时的默认值复制的，改默认值不会影响他们。
# 后台改这个设置时可以勾选「同时应用到现有用户」，核心为此排一个后台任务；这里同步执行同一个任务，
# 脚本结束时结果已经生效。这个任务核心限定同一时刻只跑一个，脚本只在部署时手动执行一次，不会撞上。
def apply_default_sidebar_categories(gtmc_categories)
  new_value = gtmc_categories.map(&:id).join("|")
  previous_value = SiteSetting.default_navigation_menu_categories
  if previous_value == new_value
    puts "default_navigation_menu_categories is up to date"
    return
  end

  SiteSetting.set(:default_navigation_menu_categories, new_value)
  Jobs::BackfillSidebarSiteSettings.new.execute(
    setting_name: "default_navigation_menu_categories",
    previous_value: previous_value,
    new_value: new_value,
  )
  puts "set default_navigation_menu_categories = #{new_value} and applied it to existing users"
end

def link_attributes(link)
  { name: link.name, value: link.value, icon: link.icon, segment: link.segment }
end

def apply_community_section(links)
  section = SidebarSection.find_by!(section_type: :community)
  existing_links = section.sidebar_urls.to_a
  if existing_links.map { |link| link_attributes(link) } == links
    puts "community sidebar section is up to date"
    return
  end

  # 走核心后台「编辑分区」用的同一个更新器：它负责保存、排序、通知在线用户刷新侧边栏、清游客缓存、记管理日志。
  # 已有链接按位置原地改写，多出的删掉，不够的新建。
  links_params =
    links.each_with_index.map do |link, index|
      existing_link = existing_links[index]
      existing_link ? link.merge(id: existing_link.id) : link
    end
  links_params += existing_links.drop(links.size).map { |link| { id: link.id, _destroy: "1" } }

  SidebarSectionUpdater.update!(
    sidebar_section: section,
    user: Discourse.system_user,
    section_params: {},
    links_params: links_params,
  )
  puts "updated community sidebar section: #{links.map { |link| link[:name] }.join(", ")}"
end

# 页脚的「新人指南」「白名单与申诉」都指向版块（「新人指南」版块里置顶的是「新人指南」帖）。地址带数据库 id，主题里没法写死，所以由这里写入。
def apply_footer_settings(theme, footer_urls)
  footer_urls.each do |setting_name, url|
    if theme.settings[setting_name].value == url
      puts "theme setting #{setting_name} is up to date"
      next
    end

    theme.update_setting(setting_name, url)
    theme.save!
    puts "set theme setting #{setting_name} = #{url}"
  end
end

theme = gtmc_theme!
gtmc_categories = CATEGORY_ICONS.map { |name, _icon| find_category!(name) }
announcement_category = find_category!(ANNOUNCEMENT_CATEGORY_NAME)
links = community_links

assert_icons_in_sprite!(theme, CATEGORY_ICONS.map(&:last) + links.map { |link| link[:icon] })

SEEDED_CATEGORY_SETTINGS_TO_DELETE.each { |setting_name| delete_seeded_category(setting_name) }

# 不开时核心按名字字母序排版块，上面写的顺序不起作用
if SiteSetting.fixed_category_positions
  puts "fixed_category_positions is up to date"
else
  SiteSetting.set(:fixed_category_positions, true)
  puts "set fixed_category_positions = true"
end

apply_category_order(gtmc_categories)
apply_default_sidebar_categories(gtmc_categories)
apply_announcement_panel_category(announcement_category)
apply_community_section(links)
apply_footer_settings(
  theme,
  footer_newcomer_guide_url: find_category!(NEWCOMER_GUIDE_CATEGORY_NAME).url,
  footer_appeal_url: find_category!(APPEAL_CATEGORY_NAME).url,
)

# 版块数据有 30 分钟的缓存，缓存键带界面语言（Site.categories_cache_key）。版块保存时核心只清当前语言的键，
# 而脚本跑在 rails runner 里，当前语言不是站点的 zh_CN，不逐个语言清掉的话，改动要等缓存过期才看得到。
I18n.available_locales.each { |locale| I18n.with_locale(locale) { Site.clear_cache } }
# 游客拿到的站点数据（侧边栏、版块）另有一层缓存
Site.clear_anon_cache!
puts "cleared site caches"
