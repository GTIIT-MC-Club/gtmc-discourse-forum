# frozen_string_literal: true

# 引导机器人初始化，可重复执行：核心自带的 discourse-narrative-bot 插件里那个教新人用论坛的机器人
# （原名 discobot）改名、换头像、改简介，新用户教程的台词换成社团口吻，教程末尾引导去「白名单与申诉」和「新人指南」。
# 名字、头像、台词都以仓库为准，在后台改了，重跑本脚本会被改回来。
#
# 机器人叫「小火把」，用户名 gtmc_torch：通用物品，不牵扯 Mojang 商标。
# 用户名也改了，不只是显示名：论坛默认只显示用户名（display_name_on_posts 为 false），
# 只改显示名的话，帖子和私信里看到的还是 discobot。插件里提及、触发词、证书都按用户名动态取，改名不会让它们失效。
# 结业证书的图片模板不动，证书上机器人的署名因此变成新用户名。
#
# 必须在下面两件事之后执行，缺了会直接报错退出：
#   1. infra/discourse/site_settings.rb 已执行；
#   2. infra/discourse/sidebar.rb 已执行（教程末尾的链接取自它写进主题设置的两个地址）。
# 发了「新人指南」置顶帖之后要重跑 sidebar.rb 和本脚本，教程里的链接才会从版块改成帖子。
#
# 由 infra/deploy-discourse.sh 调用（它把整个 infra/ 复制进容器）。
#
# 只覆盖中文（zh_CN）的台词，界面语言是英文的用户仍看到插件自带的英文。

require "digest"
require "tempfile"
require "yaml"

THEME_NAME = "GTMC"
NARRATIVE_BOT_USERNAME = "gtmc_torch"
NARRATIVE_BOT_DISPLAY_NAME = "小火把"
NARRATIVE_TEXT_LOCALE = "zh_CN"
NARRATIVE_BOT_CONTENT_DIRECTORY = File.expand_path("../content/narrative-bot", __dir__)
AVATAR_PATH = File.join(NARRATIVE_BOT_CONTENT_DIRECTORY, "avatar.png")
# 台词文件里的键相对于这个前缀（插件的翻译键）
NARRATIVE_TEXT_KEY_PREFIX = "discourse_narrative_bot"
PLACEHOLDER_PATTERN = /\{\{(\w+)\}\}/

def find_narrative_bot!
  User.find_by(id: DiscourseNarrativeBot::BOT_USER_ID) ||
    abort("narrative bot user not found; is the discourse-narrative-bot plugin enabled?")
end

def apply_username(bot)
  if bot.username == NARRATIVE_BOT_USERNAME
    puts "bot username is up to date"
    return
  end

  old_username = bot.username
  # 同步执行：核心会改写已有帖子里对旧用户名的提及，异步的话脚本结束时还没改完
  unless UsernameChanger.new(bot, NARRATIVE_BOT_USERNAME, Discourse.system_user).change(
           asynchronous: false,
         )
    abort "could not rename bot to #{NARRATIVE_BOT_USERNAME}: #{bot.errors.full_messages.join(", ")}"
  end
  puts "renamed bot #{old_username} -> #{NARRATIVE_BOT_USERNAME}"
end

def apply_display_name(bot)
  if bot.name == NARRATIVE_BOT_DISPLAY_NAME
    puts "bot display name is up to date"
    return
  end

  bot.update!(name: NARRATIVE_BOT_DISPLAY_NAME)
  puts "set bot display name = #{NARRATIVE_BOT_DISPLAY_NAME}"
end

# 插件只在简介为空时才写入默认简介（db/fixtures/001_discobot.rb），所以改翻译文案没用，要直接写资料
def apply_bio(bot, bio)
  if bot.user_profile.bio_raw == bio
    puts "bot bio is up to date"
    return
  end

  bot.user_profile.update!(bio_raw: bio)
  puts "set bot bio"
end

# 文件名带内容摘要：头像换了，名字就变，下面据此判断是否要重新上传
def apply_avatar(bot)
  abort "avatar not found at #{AVATAR_PATH}" unless File.file?(AVATAR_PATH)

  filename = "narrative-bot-avatar-#{Digest::SHA1.file(AVATAR_PATH).hexdigest[0, 12]}.png"
  if bot.uploaded_avatar&.original_filename == filename
    puts "bot avatar is up to date"
    return
  end

  # UploadCreator 会就地缩放、优化传进去的文件，所以传副本，不能传仓库里的 avatar.png
  upload =
    Tempfile.create(%w[narrative-bot-avatar .png], binmode: true) do |copy|
      copy.write(File.binread(AVATAR_PATH))
      copy.flush
      UploadCreator.new(copy, filename, type: "avatar").create_for(bot.id)
    end
  abort "avatar upload failed: #{upload.errors.full_messages.join(", ")}" unless upload.persisted?

  UserAvatar.pick_for_user!(bot, upload.id, type: :custom)
  puts "set bot avatar = upload #{upload.id} (#{filename})"
end

def read_theme_setting!(theme, setting_name)
  value = theme.settings[setting_name].value
  if value.blank?
    abort "theme setting #{setting_name} is empty; run infra/discourse/sidebar.rb first"
  end
  value
end

def flatten_texts(nested_texts, key_prefix)
  nested_texts.flat_map do |key, value|
    full_key = "#{key_prefix}.#{key}"
    value.is_a?(Hash) ? flatten_texts(value, full_key) : [[full_key, value]]
  end
end

def fill_placeholders(text, replacements)
  filled_text =
    text.gsub(PLACEHOLDER_PATTERN) do
      replacements.fetch(Regexp.last_match(1)) do
        abort "unknown placeholder {{#{Regexp.last_match(1)}}} in narrative bot text; see the header of zh_CN.yml"
      end
    end
  filled_text.strip
end

# 核心保存覆盖文案前会过一遍 HTML 清理（如把 &uarr; 还原成 ↑、&#8203; 还原成零宽空格），库里存的是清理后的文字，
# 所以要和「清理后的期望值」比较，否则每次重跑都对不上。参数与 TranslationOverride.upsert! 里的一致。
def sanitized_as_stored(text)
  TranslationOverride.new.sanitize_field(text, additional_attributes: %w[data-auto-route target])
end

# TranslationOverride.upsert! 不抛异常：值里用了英文原文没有的占位符时，只在返回值的 errors 里体现，
# 台词不会生效，页面上还是插件自带的文字。所以逐条检查，并确认键在英文原文里存在（键拼错时核心也不报错）。
def apply_narrative_text(key, text)
  unless I18n.overrides_disabled { I18n.exists?(key, :en) }
    abort "narrative bot text #{key} not found in the plugin; check zh_CN.yml against server.en.yml"
  end

  expected_value = sanitized_as_stored(text)
  stored_override = TranslationOverride.find_by(locale: NARRATIVE_TEXT_LOCALE, translation_key: key)
  if stored_override&.value == expected_value
    puts "narrative bot text #{key} is up to date"
    return
  end

  override = TranslationOverride.upsert!(NARRATIVE_TEXT_LOCALE, key, text)
  if override.errors.any?
    abort "narrative bot text #{key} was rejected: #{override.errors.full_messages.join(", ")}"
  end

  puts "set #{NARRATIVE_TEXT_LOCALE} text #{key}"
end

bot = find_narrative_bot!
theme =
  Theme.find_by(name: THEME_NAME) ||
    abort("theme #{THEME_NAME} not found; run infra/discourse/import_theme.rb first")
replacements = {
  "bot_name" => NARRATIVE_BOT_DISPLAY_NAME,
  "newcomer_guide_url" => read_theme_setting!(theme, :footer_newcomer_guide_url),
  "appeal_url" => read_theme_setting!(theme, :footer_appeal_url),
}
texts = YAML.safe_load_file(File.join(NARRATIVE_BOT_CONTENT_DIRECTORY, "zh_CN.yml"))

apply_username(bot)
apply_display_name(bot)
apply_bio(bot, fill_placeholders(texts.fetch("bio"), replacements))
apply_avatar(bot)

flatten_texts(texts.fetch(NARRATIVE_TEXT_KEY_PREFIX), NARRATIVE_TEXT_KEY_PREFIX).each do |key, text|
  apply_narrative_text(key, fill_placeholders(text, replacements))
end
