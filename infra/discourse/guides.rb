# frozen_string_literal: true

# 把仓库里的新手教程（一个 Markdown 文件一个话题）发到「新人指南」版块，可重复执行。
# 仓库是唯一的源：论坛上的首帖被锁定，非管理人员不能编辑；管理人员在论坛上改了也会在下次执行时被覆盖。
# 写作约定（front matter、相对链接）见 infra/content/guides/README.md。
#
# 每个文件对应的话题记在核心的永久链接（Permalink）里，地址是 wiki/<去掉 .md 的相对路径>，
# 例如 launcher.md → /wiki/launcher。这个地址顺带成了教程的固定网址，话题改标题、换 slug 都不会变。
# 不另建表、不用自定义字段：永久链接是核心公开的模型，管理员在后台「永久链接」页能看到和修改。
#
# 执行分三步，任何一步发现问题都在写入之前退出：
#   1. 读入并检查所有文件：front matter、标题不重复、每个指向 .md 的相对链接都能找到对应文件；
#      并决定每个文件对应哪个话题（已有永久链接 / 认领版块里同名的话题 / 新建）。
#   2. 新建或认领话题、建永久链接，再把标题改成 front matter 里的标题。
#      标题要在渲染正文之前改好：话题地址带 slug，slug 跟着标题变。
#   3. 渲染正文（相对链接换成话题地址，加上「从仓库同步」的页脚），有变化才修订；锁定首帖、取消 wiki；
#      目录（index.md）在版块内置顶。
#
# 链接换成 /t/<slug>/<id> 而不是 /wiki/<路径>：核心只为指向话题地址的链接建反向链接
# （被链接的帖子底下显示「谁链接了我」），换成永久链接地址就没有了。
#
# 用法（在自有机器上）：把整个 infra/ 复制进容器，教程目录作为参数（以后教程可能搬到单独的仓库，所以不写死路径）：
#   docker cp infra app:/tmp/gtmc-infra && docker exec -u discourse -w /var/www/discourse app \
#     bundle exec rails runner /tmp/gtmc-infra/discourse/guides.rb /tmp/gtmc-infra/content/guides
# 本机开发站：在 Discourse 源码目录执行
#   bin/rails runner <仓库>/infra/discourse/guides.rb <仓库>/infra/content/guides
#
# 必须在 site_settings.rb 之后执行（「新人指南」版块由它创建）。执行顺序见 infra/content/admin-setup.md。

require "pathname"
require "yaml"

GUIDE_CATEGORY_NAME = "新人指南"
# 给维护者看的说明，不是教程，任何一层目录里的都不发
MAINTAINER_NOTES_FILE_NAME = "README.md"
GUIDE_FILE_EXTENSION = ".md"
PERMALINK_PREFIX = "wiki/"
# 目录帖，在版块内置顶。只认最外层的 index.md，子目录里的 index.md 是普通教程
INDEX_GUIDE_PATH = "index"
# 页脚「在 GitHub 上编辑」的地址前缀。教程搬到别的仓库或目录时必须一起改
SOURCE_EDIT_URL_BASE =
  "https://github.com/GTIIT-MC-Club/gtmc-discourse/edit/main/infra/content/guides/"
# 文件路径会原样成为 /wiki/ 下的地址。只允许小写字母、数字和连字符，地址就不需要转义，
# 核心保存永久链接时对非 ASCII 字符做的编码也不会让按路径查找对不上
GUIDE_PATH_PATTERN = %r{\A[a-z0-9][a-z0-9-]*(/[a-z0-9][a-z0-9-]*)*\z}
FRONT_MATTER_PATTERN = /\A---\r?\n(.*?)\r?\n---\r?\n/m
# 新建话题时的临时正文：第 3 步立刻换成真正的正文。先占位是因为正文里的链接要等所有话题都建好才知道地址
PLACEHOLDER_RAW = "这篇教程正在从仓库同步，稍后刷新即可看到正文。"

# 只认 CommonMark 的围栏代码块（``` 或 ~~~，最多缩进 3 格），里面的链接不检查也不改写
FENCE_OPENING_PATTERN = /\A {0,3}(`{3,}|~{3,})/
INLINE_CODE_OR_TEXT_PATTERN = /(?<code>(?<ticks>`+).*?\k<ticks>)|(?<text>[^`]+|`+)/
# 行内链接 [文字](目标 "可选标题") 和引用式链接的定义 [名字]: 目标，捕获组 2 是目标
INLINE_LINK_PATTERN = /(\]\(\s*<?)([^)\s>]+)/
REFERENCE_DEFINITION_PATTERN = /\A( {0,3}\[[^\]]+\]:\s*<?)([^\s>]+)/
# 带协议的地址（https:、mailto: 等）、站内绝对路径、本页锚点，都不需要改写
ABSOLUTE_TARGET_PATTERN = %r{\A([a-z][a-z0-9+.-]*:|/|#)}i

Guide = Struct.new(:path, :source_path, :title, :body, keyword_init: true)

def guides_directory!
  directory = ARGV.first
  abort "usage: rails runner guides.rb <path to the guides directory>" if directory.nil?
  abort "#{directory} is not a directory" unless File.directory?(directory)

  directory
end

def find_category!(name)
  Category.find_by(name: name) ||
    abort("category #{name} not found; run infra/discourse/site_settings.rb first")
end

def parse_front_matter!(source_path, content)
  match =
    FRONT_MATTER_PATTERN.match(content) ||
      abort("#{source_path}: must start with front matter (a --- line, title: ..., a --- line)")

  front_matter =
    begin
      YAML.safe_load(match[1])
    rescue Psych::SyntaxError => error
      abort "#{source_path}: front matter is not valid YAML: #{error.message}"
    end
  title = front_matter["title"] if front_matter.is_a?(Hash)
  unless title.is_a?(String) && title.strip.present?
    abort "#{source_path}: front matter has no title"
  end

  [title.strip, match.post_match.sub(/\A(\r?\n)+/, "")]
end

def load_guide!(directory, source_path)
  path = source_path.delete_suffix(GUIDE_FILE_EXTENSION)
  unless path.match?(GUIDE_PATH_PATTERN)
    abort "#{source_path}: file and directory names may only use lowercase letters, digits and hyphens"
  end

  title, body = parse_front_matter!(source_path, File.read(File.join(directory, source_path)))
  Guide.new(path: path, source_path: source_path, title: title, body: body)
end

def load_guides!(directory)
  source_paths =
    Dir
      .glob("**/*#{GUIDE_FILE_EXTENSION}", base: directory)
      .reject { |source_path| File.basename(source_path) == MAINTAINER_NOTES_FILE_NAME }
      .sort
  abort "no guides found in #{directory}" if source_paths.empty?

  source_paths.map { |source_path| load_guide!(directory, source_path) }
end

# 同名会让「认领同名话题」认错，也会让读者分不清
def assert_unique_titles!(guides)
  duplicated_titles = guides.group_by(&:title).select { |_title, same_title| same_title.size > 1 }
  return if duplicated_titles.empty?

  abort "guides share a title: " +
          duplicated_titles
            .map { |title, same_title| "#{title} (#{same_title.map(&:source_path).join(", ")})" }
            .join("; ")
end

def map_outside_inline_code(line)
  line.gsub(INLINE_CODE_OR_TEXT_PATTERN) do
    match = Regexp.last_match
    match[:text] ? yield(match[:text]) : match[:code]
  end
end

# 对正文里每个链接目标调用块，用块的返回值替换它；围栏代码块和行内代码里的不算链接。
# 检查和渲染都走这里，两边认定的「链接」才一致。
def map_link_targets(markdown, &replace_target)
  closing_fence_pattern = nil
  markdown
    .each_line
    .map do |line|
      if closing_fence_pattern
        closing_fence_pattern = nil if line.match?(closing_fence_pattern)
        next line
      end

      if (opening_fence = line[FENCE_OPENING_PATTERN, 1])
        # 结束围栏用同一种字符，且不短于开始围栏
        closing_fence_pattern =
          /\A {0,3}#{Regexp.escape(opening_fence[0])}{#{opening_fence.length},}\s*$/
        next line
      end

      line =
        line.sub(REFERENCE_DEFINITION_PATTERN) do
          prefix, target = Regexp.last_match[1], Regexp.last_match[2]
          "#{prefix}#{replace_target.call(target)}"
        end
      map_outside_inline_code(line) do |text|
        text.gsub(INLINE_LINK_PATTERN) do
          prefix, target = Regexp.last_match[1], Regexp.last_match[2]
          "#{prefix}#{replace_target.call(target)}"
        end
      end
    end
    .join
end

# 返回 nil：目标不需要改写。否则返回 [被链接的教程（找不到时为 nil）, 锚点（没有时为 nil）]
def resolve_link_target(guide, target, guides_by_source_path)
  return nil if target.match?(ABSOLUTE_TARGET_PATTERN)

  relative_path, anchor = target.split("#", 2)
  linked_source_path =
    Pathname.new(File.dirname(guide.source_path)).join(relative_path).cleanpath.to_s
  [guides_by_source_path[linked_source_path], anchor]
end

# 相对链接只能指向另一篇教程：图片、README 之类的相对路径在论坛上同样会失效
def assert_links_resolve!(guides, guides_by_source_path)
  broken_links = []
  guides.each do |guide|
    map_link_targets(guide.body) do |target|
      resolved = resolve_link_target(guide, target, guides_by_source_path)
      broken_links << "#{guide.source_path}: #{target}" if resolved && resolved.first.nil?
      target
    end
  end
  return if broken_links.empty?

  abort "relative links must point to another guide file; these do not:\n  " +
          broken_links.join("\n  ")
end

def permalink_url(guide)
  "#{PERMALINK_PREFIX}#{guide.path}"
end

def guide_permalinks
  Permalink.where("url LIKE ?", "#{PERMALINK_PREFIX}%")
end

def existing_topic_from_permalink!(guide, permalink)
  # 话题被删（核心的软删除）后 permalink.topic 为 nil。不自动重建：删帖可能是有意的，交给管理员决定
  return permalink.topic if permalink.topic

  abort "permalink /#{permalink.url} for #{guide.source_path} does not point at a live topic " \
          "(topic id #{permalink.topic_id.inspect}); restore the topic, or delete the permalink " \
          "in admin → permalinks to publish a fresh topic, then re-run"
end

# 手工发过的同名话题（生产站上「启动器是什么」「版本号和模组加载器」两篇）直接接管，不重复发一篇
def adoptable_topic!(guide, category, claimed_topic_ids)
  candidates =
    Topic
      .where(category_id: category.id, archetype: Archetype.default, title: guide.title)
      .where.not(id: claimed_topic_ids)
      .to_a
  if candidates.size > 1
    abort "#{guide.source_path}: several topics in #{category.name} are titled #{guide.title} " \
            "(ids #{candidates.map(&:id).join(", ")}); close or rename the extra ones, then re-run"
  end

  candidates.first
end

# 第 1 步的一部分：只决定每篇对应哪个话题，不写入
def plan_topics!(guides, category)
  claimed_topic_ids = guide_permalinks.where.not(topic_id: nil).pluck(:topic_id)
  guides.to_h do |guide|
    permalink = Permalink.find_by_url(permalink_url(guide))
    plan =
      if permalink
        { topic: existing_topic_from_permalink!(guide, permalink) }
      elsif (topic = adoptable_topic!(guide, category, claimed_topic_ids))
        claimed_topic_ids << topic.id
        { topic: topic, adopted: true }
      else
        {}
      end
    [guide.path, plan]
  end
end

def create_topic!(guide, category)
  # 跳过核心对用户输入的校验（标题长度、正文太短、标题与已有话题重复等）：
  # 内容由仓库评审把关，占位正文也一定过不了最短长度
  post =
    PostCreator.create!(
      Discourse.system_user,
      title: guide.title,
      raw: PLACEHOLDER_RAW,
      category: category.id,
      skip_validations: true,
    )
  puts "created topic #{post.topic_id} for #{guide.source_path}"
  post.topic
end

def warn_if_edited_on_forum(guide, post)
  return if post.last_editor_id == Discourse.system_user.id

  editor = User.find_by(id: post.last_editor_id)
  puts "warning: #{guide.source_path}: the forum copy was last edited by " \
         "#{editor&.username || "user #{post.last_editor_id}"}; overwriting it with the repository version"
end

def revise_first_post!(guide, post, changes)
  warn_if_edited_on_forum(guide, post)
  # force_new_version：系统账号在编辑宽限期内的连续修改默认会并进上一个版本，每次同步单独留一个版本才好对照仓库的提交。
  # bypass_bump：同步不是新内容，不把话题顶到最新列表前面
  revised =
    post.revise(
      Discourse.system_user,
      changes,
      bypass_bump: true,
      force_new_version: true,
      skip_validations: true,
    )
  return if revised

  abort "#{guide.source_path}: could not revise post #{post.id}: #{post.errors.full_messages.join(", ")}"
end

# 第 2 步：返回 { 路径 => 话题 }，以及有改动的教程路径
def ensure_topics!(guides, category, topic_plans)
  changed_paths = Set.new
  topics_by_path =
    guides.to_h do |guide|
      plan = topic_plans.fetch(guide.path)
      topic = plan[:topic]
      if topic.nil?
        topic = create_topic!(guide, category)
        changed_paths << guide.path
      elsif plan[:adopted]
        puts "adopted topic #{topic.id} (#{topic.title}) for #{guide.source_path}"
        changed_paths << guide.path
      end

      unless Permalink.find_by_url(permalink_url(guide))
        Permalink.create!(url: permalink_url(guide), topic_id: topic.id)
        puts "created permalink /#{permalink_url(guide)} → topic #{topic.id}"
      end

      if topic.title != guide.title
        revise_first_post!(guide, topic.first_post, title: guide.title)
        puts "retitled topic #{topic.id} to #{guide.title}"
        changed_paths << guide.path
      end

      [guide.path, topic.reload]
    end
  [topics_by_path, changed_paths]
end

def source_footer(guide)
  edit_url = "#{SOURCE_EDIT_URL_BASE}#{guide.source_path}"
  <<~MARKDOWN
    ---

    <small>这篇教程从社团仓库的 `#{guide.source_path}` 同步而来，在论坛上直接修改会在下次同步时被覆盖。发现写错了或想补充：[在 GitHub 上修改源文件](#{edit_url})，或者在下面回复。</small>
  MARKDOWN
end

def render_raw(guide, topics_by_path, guides_by_source_path)
  body =
    map_link_targets(guide.body) do |target|
      resolved = resolve_link_target(guide, target, guides_by_source_path)
      next target if resolved.nil?

      linked_guide, anchor = resolved
      url = topics_by_path.fetch(linked_guide.path).relative_url
      anchor ? "#{url}##{anchor}" : url
    end
  # 和核心保存帖子时一样规整空白（PostCreator、PostRevisor 都这么做），否则每次比较都不相等
  TextCleaner.normalize_whitespaces("#{body.rstrip}\n\n#{source_footer(guide)}").rstrip
end

def sync_first_post!(guide, topic, raw)
  post = topic.first_post
  changes = {}
  changes[:raw] = raw if post.raw != raw
  # 设成 wiki 的帖子任何有权限的人都能改，与「仓库为准」矛盾（T6 时首帖曾设成 wiki）
  changes[:wiki] = false if post.wiki
  return false if changes.empty?

  revise_first_post!(guide, post, changes)
  puts "revised #{guide.source_path} (topic #{topic.id}): #{changes.keys.join(", ")}"
  true
end

# 锁定的帖子只有管理人员能改（lib/guardian/post_guardian.rb 的 can_edit_post?），作者本人也不行。回复不受影响
def lock_first_post!(guide, topic)
  post = topic.first_post.reload
  return false if post.locked?

  # 每次锁定都会记一条管理日志，所以只在没锁时锁
  PostLocker.new(post, Discourse.system_user).lock
  puts "locked the first post of #{guide.source_path} (topic #{topic.id})"
  true
end

# 只在版块内置顶，不全局置顶；「新人指南」置顶帖由管理员手工维护，这里不碰别的话题
def pin_index_topic!(topic)
  return false if topic.pinned_at.present? && !topic.pinned_globally

  topic.update_pinned(true, false)
  puts "pinned topic #{topic.id} in its category"
  true
end

def warn_about_orphaned_permalinks(guides)
  guide_urls = guides.map { |guide| permalink_url(guide) }
  guide_permalinks
    .where.not(url: guide_urls)
    .order(:url)
    .each do |permalink|
      puts "warning: permalink /#{permalink.url} (topic #{permalink.topic_id.inspect}) has no guide file; " \
             "left as is: delete the topic and the permalink in admin if the guide was removed on purpose"
    end
end

directory = guides_directory!
guides = load_guides!(directory)
guides_by_source_path = guides.index_by(&:source_path)
assert_unique_titles!(guides)
assert_links_resolve!(guides, guides_by_source_path)
category = find_category!(GUIDE_CATEGORY_NAME)
topic_plans = plan_topics!(guides, category)

topics_by_path, changed_paths = ensure_topics!(guides, category, topic_plans)

guides.each do |guide|
  topic = topics_by_path.fetch(guide.path)
  raw = render_raw(guide, topics_by_path, guides_by_source_path)
  changed = sync_first_post!(guide, topic, raw)
  changed = lock_first_post!(guide, topic) || changed
  changed = pin_index_topic!(topic.reload) || changed if guide.path == INDEX_GUIDE_PATH
  changed_paths << guide.path if changed

  puts "guide #{guide.source_path} is up to date" unless changed_paths.include?(guide.path)
end

warn_about_orphaned_permalinks(guides)
