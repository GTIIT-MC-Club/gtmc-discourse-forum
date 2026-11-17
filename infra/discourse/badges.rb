# frozen_string_literal: true

# 社团徽章初始化，可重复执行：「社团成就」徽章分组、四枚社团徽章、核心自带徽章的中文改名。
# 徽章的名称、说明、图标、授予条件都以这里为准，在后台改了，重跑本脚本会被改回来。
#
# 必须在下面两件事之后执行，缺了会直接报错退出：
#   1. infra/discourse/site_settings.rb 已执行（授予条件里引用的版块由它创建）；
#   2. GTMC 主题已导入（徽章图标来自主题的图标精灵，见 theme/README.md「图标」）。
#
# 用法（在自有机器上）：
#   docker cp badges.rb app:/tmp/ && docker exec -u discourse -w /var/www/discourse app \
#     bundle exec rails runner /tmp/badges.rb
#
# 自动授予：授予条件写成 SQL 查询，核心每天跑一次（触发器「每日更新」），所以新徽章最迟一天后才会出现；
# 想立刻看到结果，在 rails runner 里执行 BadgeGranter.backfill(Badge.find_by(name: "建筑师"))。
# 查询只读 badge_posts 视图（核心提供：已排除删除的帖子、私信、受限版块、悄悄话），所以老玩家俱乐部这类
# 受限版块里的帖子不会被统计。条件不再满足（比如帖子被删）时，下一次每日更新会收回徽章。
#
# 不需要打开隐藏设置 enable_badge_sql：脚本直接写数据库，核心定时授予时也不检查它。
# 它只管后台徽章编辑页的「查询」输入框和预览接口，打开后任何管理员都能在页面上写任意 SQL，权限过大，所以保持关闭。
# 这也意味着管理员在后台看不到这些查询，要看就读本文件。
#
# 手工授予的徽章（引路人）没有查询，由管理员在徽章页「授予」。自动授予的徽章不要同时手工授予：
# 核心每天按查询结果核对，只会收回「系统授予」的记录，手工授予的不受影响，但会让徽章的含义混乱。

THEME_NAME = "GTMC"
BADGE_GROUPING_NAME = "社团成就"
# 排在核心自带分组（位置 10 起）前面，公开徽章页最先看到社团的徽章
BADGE_GROUPING_POSITION = 0
CORE_BADGE_TEXT_LOCALE = "zh_CN"

BUILDING_CATEGORY_NAME = "建筑展示"
REDSTONE_CATEGORY_NAME = "红石与技术"
EVENT_CATEGORY_NAME = "活动"

# 授予门槛。200 人的社团里「被 3 人点赞」已经是明显认可；再高，一个学期里没几个人能拿到。
MIN_LIKES_FOR_BUILDER = 3
MIN_LIKES_FOR_REDSTONE_ENGINEER = 1
MIN_EVENTS_FOR_REGULAR = 3
# 发帖模板里的小标题（infra/discourse/site_settings.rb 的 CATEGORIES）。红石与技术版块的帖子
# 保留这三项，说明作者按模板写了目标、版本和现状。模板改了这里要同步改。
REDSTONE_TEMPLATE_HEADINGS = %w[【目标】 【版本与依赖】 【现状】]
# 「截图」按上传的图片文件判断，压缩包、存档等其他附件不算
SCREENSHOT_FILE_EXTENSIONS = %w[png jpg jpeg gif webp avif]

def sql_quote(value)
  ActiveRecord::Base.connection.quote(value)
end

def builder_query
  <<~SQL.strip
    SELECT p.user_id, p.id AS post_id, CURRENT_TIMESTAMP AS granted_at
    FROM badge_posts p
    JOIN topics t ON t.id = p.topic_id
    JOIN categories c ON c.id = t.category_id
    WHERE c.name = #{sql_quote(BUILDING_CATEGORY_NAME)}
      AND p.post_number = 1
      AND p.post_type = 1
      AND p.like_count >= #{MIN_LIKES_FOR_BUILDER}
      AND EXISTS (
        SELECT 1
        FROM upload_references ur
        JOIN uploads u ON u.id = ur.upload_id
        WHERE ur.target_type = 'Post'
          AND ur.target_id = p.id
          AND u.extension IN (#{SCREENSHOT_FILE_EXTENSIONS.map { |extension| sql_quote(extension) }.join(", ")})
      )
  SQL
end

def redstone_engineer_query
  heading_conditions =
    REDSTONE_TEMPLATE_HEADINGS.map do |heading|
      "AND position(#{sql_quote(heading)} IN device.raw) > 0"
    end
  <<~SQL.strip
    SELECT device.user_id, device.id AS post_id, CURRENT_TIMESTAMP AS granted_at
    FROM badge_posts device
    JOIN topics device_topic ON device_topic.id = device.topic_id
    JOIN categories c ON c.id = device_topic.category_id
    WHERE c.name = #{sql_quote(REDSTONE_CATEGORY_NAME)}
      AND device.post_number = 1
      AND device.post_type = 1
      AND device.like_count >= #{MIN_LIKES_FOR_REDSTONE_ENGINEER}
      #{heading_conditions.join("\n      ")}
      AND EXISTS (
        SELECT 1
        FROM badge_posts answer
        JOIN topics answered_topic ON answered_topic.id = answer.topic_id
        WHERE answer.user_id = device.user_id
          AND answer.post_number > 1
          AND answer.post_type = 1
          AND answered_topic.category_id = device_topic.category_id
          AND answered_topic.user_id <> device.user_id
      )
  SQL
end

# 「参加」只能近似为「报名」：活动帖的模板要求参与者在帖子下回帖报名，核心不记录谁真的到场。
def event_regular_query
  <<~SQL.strip
    SELECT p.user_id, CURRENT_TIMESTAMP AS granted_at
    FROM badge_posts p
    JOIN topics t ON t.id = p.topic_id
    JOIN categories c ON c.id = t.category_id
    WHERE c.name = #{sql_quote(EVENT_CATEGORY_NAME)}
      AND p.post_number > 1
      AND p.post_type = 1
      AND t.user_id <> p.user_id
    GROUP BY p.user_id
    HAVING COUNT(DISTINCT p.topic_id) >= #{MIN_EVENTS_FOR_REGULAR}
  SQL
end

# 图标取自主题的图标精灵（theme/icons/），与版块、侧边栏用同一套：砖墙、齿轮、蛋糕、指南针。
# 都不开「可多次授予」：同一件事做十次也只该有一枚。
def club_badges
  [
    {
      name: "建筑师",
      badge_type_id: BadgeType::Silver,
      icon: "gtmc-bricks",
      description: "在「#{BUILDING_CATEGORY_NAME}」发过带截图的作品，并收到至少 #{MIN_LIKES_FOR_BUILDER} 个赞",
      long_description: <<~TEXT.strip,
        在「#{BUILDING_CATEGORY_NAME}」版块发出的作品帖里附有截图，并且这篇帖子收到至少 #{MIN_LIKES_FOR_BUILDER} 个赞。系统每天自动核对一次。

        系统看不出作品是不是原创。搬运别人的作品，管理员会删帖，删帖之后下一次核对时徽章会被收回。
      TEXT
      allow_title: true,
      target_posts: true,
      show_posts: true,
      query: builder_query,
    },
    {
      name: "红石工程师",
      badge_type_id: BadgeType::Silver,
      icon: "gtmc-gear",
      description: "在「#{REDSTONE_CATEGORY_NAME}」发过写清目标、版本和现状的装置帖，也回答过别人的问题",
      long_description: <<~TEXT.strip,
        同时满足：

        - 在「#{REDSTONE_CATEGORY_NAME}」发过装置帖，保留了发帖模板里的「目标」「版本与依赖」「现状」，并且收到至少 #{MIN_LIKES_FOR_REDSTONE_ENGINEER} 个赞；
        - 在这个版块里回复过别人发的话题。

        系统每天自动核对一次。它只能检查模板的小标题还在、有人点赞、回复过别人，看不出装置能不能复现、回复算不算答到点上；
        发现有人只是凑条件，管理员会处理帖子。
      TEXT
      allow_title: true,
      target_posts: true,
      show_posts: true,
      query: redstone_engineer_query,
    },
    {
      name: "活动常客",
      badge_type_id: BadgeType::Bronze,
      icon: "gtmc-cake",
      description: "在 #{MIN_EVENTS_FOR_REGULAR} 个以上不同的「#{EVENT_CATEGORY_NAME}」帖子下报名过",
      long_description: <<~TEXT.strip,
        在「#{EVENT_CATEGORY_NAME}」版块里，别人发起的 #{MIN_EVENTS_FOR_REGULAR} 个以上不同的活动帖下回帖报名过。系统每天自动核对一次。

        系统只能看到报名，看不到你有没有到场。
      TEXT
      allow_title: true,
      target_posts: false,
      show_posts: false,
      query: event_regular_query,
    },
    {
      name: "引路人",
      badge_type_id: BadgeType::Gold,
      icon: "gtmc-compass",
      description: "带会了至少一位完全的新手",
      long_description: <<~TEXT.strip,
        带会了至少一位完全的新手：对方的第一篇帖子，或者第一次进服，是你带的。

        这枚徽章由管理员手工授予，系统没有办法自动判断。认为自己带过新人，或者想推荐别人，请联系管理员。
      TEXT
      allow_title: true,
      target_posts: false,
      show_posts: false,
      query: nil,
    },
  ]
end

# 核心自带徽章不改 name 字段：核心把它列为受保护字段，而且有代码按英文名找徽章（引导机器人找 Certified），
# 改了会找不到。所以只用翻译覆盖改中文界面里显示的名称和说明，徽章本身不动；
# 用英文界面的用户仍看到英文原名。
# 键是核心徽章的 i18n 名（英文名小写加下划线）。
# 「初来乍到」是信任等级 1 的徽章，仍留在核心的「信任等级」分组里，不在「社团成就」分组。
CORE_BADGE_TEXTS = {
  "basic_user" => {
    name: "初来乍到",
    description: "升到信任等级 1，走完了新手期，可以正常发言了",
  },
  "first_like" => {
    name: "点亮火把",
    description: "给别人的帖子点了第一个赞",
  },
  "first_link" => {
    name: "搭好第一座桥",
    description: "在帖子里放了指向另一个话题的链接",
  },
  "first_emoji" => {
    name: "气氛组",
    description: "在帖子里用了表情符号",
  },
  "first_quote" => {
    name: "引经据典",
    description: "引用了别人的帖子",
  },
  "first_mention" => {
    name: "喊人组队",
    description: "在帖子里提及（@）了其他用户",
  },
  "first_share" => {
    name: "传送门",
    description: "分享了一个帖子的链接",
  },
}

def find_category!(name)
  Category.find_by(name: name) ||
    abort("category #{name} not found; run infra/discourse/site_settings.rb first")
end

def assert_icons_in_sprite!(badges)
  theme =
    Theme.find_by(name: THEME_NAME) ||
      abort("theme #{THEME_NAME} not found; run infra/discourse/import_theme.rb first")
  icon_names = badges.map { |badge| badge[:icon] }
  missing_icons = icon_names - SvgSprite.custom_svgs(theme.id).keys
  return if missing_icons.empty?

  abort "icons missing from the #{THEME_NAME} theme sprite: #{missing_icons.join(", ")}; re-import theme/"
end

# 核心的 preview 不抛异常，查询写错时把错误放在返回值的 errors 里
def assert_query_runs!(badge_attributes)
  return if badge_attributes[:query].nil?

  preview =
    BadgeGranter.preview(
      badge_attributes[:query],
      target_posts: badge_attributes[:target_posts],
      trigger: badge_attributes[:trigger],
    )
  if preview[:errors]
    abort "query of badge #{badge_attributes[:name]} is invalid: #{preview[:errors]}"
  end

  puts "query of badge #{badge_attributes[:name]} runs; it matches #{preview[:grant_count]} users now"
end

def find_or_create_badge_grouping
  grouping = BadgeGrouping.find_by(name: BADGE_GROUPING_NAME)
  return grouping if grouping

  grouping = BadgeGrouping.create!(name: BADGE_GROUPING_NAME, position: BADGE_GROUPING_POSITION)
  puts "created badge grouping #{BADGE_GROUPING_NAME}"
  grouping
end

def apply_badge(badge_attributes, grouping)
  # 触发器「每日更新」：不依赖帖子或用户的变更事件，核心每天对全站跑一遍查询
  wanted =
    badge_attributes.merge(
      badge_grouping_id: grouping.id,
      trigger: Badge::Trigger::None,
      multiple_grant: false,
      listable: true,
      enabled: true,
      auto_revoke: true,
    )
  assert_query_runs!(wanted)

  badge = Badge.find_or_initialize_by(name: wanted[:name])
  # description 的读取器会先查翻译再回落到存的值，比较要看存的原值
  changed_fields = wanted.keys.reject { |field| badge[field] == wanted[field] }
  if changed_fields.empty?
    puts "badge #{badge.name} is up to date"
    return
  end

  was_new = badge.new_record?
  badge.update!(wanted)
  puts(
    (
      if was_new
        "created badge #{badge.name}"
      else
        "updated badge #{badge.name}: #{changed_fields.join(", ")}"
      end
    ),
  )
end

# TranslationOverride.upsert! 不抛异常：值里用了英文原文没有的占位符等校验失败时，只在返回值的 errors 里体现，
# 文案不会生效。所以逐条检查，并确认键在英文原文里存在（键拼错时核心也不报错）。
def apply_core_badge_text(i18n_name, field, value)
  key = "badges.#{i18n_name}.#{field}"
  unless I18n.overrides_disabled { I18n.exists?(key, :en) }
    abort "core badge text #{key} not found; check the badge name in CORE_BADGE_TEXTS"
  end

  if TranslationOverride.find_by(locale: CORE_BADGE_TEXT_LOCALE, translation_key: key)&.value ==
       value
    puts "core badge text #{key} is up to date"
    return
  end

  override = TranslationOverride.upsert!(CORE_BADGE_TEXT_LOCALE, key, value)
  if override.errors.any?
    abort "core badge text #{key} was rejected: #{override.errors.full_messages.join(", ")}"
  end

  puts "set #{CORE_BADGE_TEXT_LOCALE} text #{key} = #{value}"
end

[BUILDING_CATEGORY_NAME, REDSTONE_CATEGORY_NAME, EVENT_CATEGORY_NAME].each do |name|
  find_category!(name)
end
badges = club_badges
assert_icons_in_sprite!(badges)

grouping = find_or_create_badge_grouping
badges.each { |badge_attributes| apply_badge(badge_attributes, grouping) }

CORE_BADGE_TEXTS.each do |i18n_name, texts|
  texts.each { |field, value| apply_core_badge_text(i18n_name, field, value) }
end
