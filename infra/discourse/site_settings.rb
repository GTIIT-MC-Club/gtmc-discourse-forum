# 站点设置与版块初始化，可重复执行。
# 用法（在自有机器上）：
#   docker cp site_settings.rb app:/tmp/ && docker exec -u discourse -w /var/www/discourse app \
#     bundle exec rails runner /tmp/site_settings.rb
# 设置名写错会直接报错退出，不会静默跳过。设置名以当前版本 config/site_settings.yml 为准。

SETTINGS = {
  title: "GTMC 论坛",
  site_description: "广东以色列理工学院 Minecraft 社团",
  default_locale: "zh_CN",
  force_https: true,

  # 准入：仅校园邮箱可注册，游客只读公开版块
  allowed_email_domains: "gtiit.edu.cn",
  login_required: false,
  invite_only: false,
  must_approve_users: false,

  # 中文社区：标题和正文的最短长度放宽，开启中文搜索分词
  min_topic_title_length: 4,
  min_post_length: 4,
  min_first_post_length: 6,
  search_tokenize_chinese: true,

  # 信任等级门槛：Discourse 默认值按万人级社区设计（TL2 要进 20 个话题、读 100 帖、来访 15 天），
  # 本站约 200 人，一天可能只新增一两个话题，照默认值一个学期也升不到 TL2，
  # 用户会觉得「发了帖也没反应」。下面把门槛压到正常参与一两周就能自然达到的量级。
  tl1_requires_topics_entered: 3, # 默认 5；话题总量少，看 3 个不同的话题就该能发言
  tl1_requires_read_posts: 15, # 默认 30
  tl1_requires_time_spent_mins: 5, # 默认 10；一次认真浏览的时间
  tl2_requires_topics_entered: 10, # 默认 20
  tl2_requires_read_posts: 50, # 默认 100
  tl2_requires_time_spent_mins: 30, # 默认 60
  tl2_requires_days_visited: 7, # 默认 15；两周内来 7 天已经算常客
  tl2_requires_topic_reply_count: 2, # 默认 3
  # TL3（常驻）默认要求在 100 天窗口内来访 50 天，成员一学期也就十几周，几乎没人能达到。
  tl3_time_period: 60, # 默认 100；窗口缩到一个学期
  tl3_requires_days_visited: 30, # 默认 50；60 天里来 30 天算常驻
  tl3_promotion_min_duration: 30, # 默认 100；满足条件后还要空等 100 天，对两年制的社团太长
  tl3_requires_topics_replied_to: 5, # 默认 10
  tl3_requires_topics_viewed: 20, # 默认 25；窗口内新话题的百分比
  tl3_requires_posts_read: 20, # 默认 25；窗口内新帖的百分比
  tl3_requires_topics_viewed_all_time: 100, # 默认 200
  tl3_requires_posts_read_all_time: 250, # 默认 500
  tl3_requires_likes_given: 15, # 默认 30
  tl3_requires_likes_received: 10, # 默认 20

  # 备份：每天一次，保留 7 份（存在 /var/discourse/shared/standalone/backups）
  backup_frequency: 1,
  maximum_backups: 7,
}

SETTINGS.each do |name, value|
  SiteSetting.set(name, value)
  puts "set #{name} = #{value}"
end

# 版块。permissions 为 nil 表示所有人可见；否则按用户组限制。
# topic_template 是发帖时预填进正文的模板，topic_title_placeholder 是标题框里的灰字提示。
CATEGORIES = [
  {
    name: "公告",
    color: "E45735",
    desc: "社团与服务器公告",
    permissions: {
      everyone: :readonly,
      staff: :full,
    },
    topic_title_placeholder: "日期 + 事件，例如「11 月 3 日 服务器例行维护」",
    topic_template: <<~TEMPLATE,
      【类型】维护 / 活动 / 规则变更 / 其他
      【时间】几月几日 几点，预计持续多久
      【影响范围】哪个服务器、会影响谁
      【大家需要做什么】

      有问题请到「白名单与申诉」发帖，不要在公告下面追问，方便后来的人按标题找到信息。
    TEMPLATE
  },
  {
    name: "建筑展示",
    color: "5DBB47",
    desc: "晒出你的建筑、存档截图与巡礼",
    topic_title_placeholder: "作品名 + 一句话介绍",
    topic_template: <<~TEMPLATE,
      【作品名】
      【坐标】进服后按 F3 查看，或写「出生点向东南 200 格」
      【截图】至少一张全景、一张细节，直接拖进编辑框就行
      【说明】用了什么材质包、参考了哪个教程
      【参观须知】是否需要提前打招呼、附近有没有危险区域（岩浆、刷怪塔）

      建得糙也没关系，发出来才有人夸。
    TEMPLATE
  },
  {
    name: "红石与技术",
    color: "D0312D",
    desc: "红石机器、生电、命令方块与数据包",
    topic_title_placeholder: "机器名 + 一句话说明目标",
    topic_template: <<~TEMPLATE,
      【目标】这个装置要做什么、达成什么指标，例如「每小时 8000 铁锭」
      【版本与依赖】服务器版本、是否需要数据包或命令方块
      【现状】已经做到哪一步，卡在哪里
      【参考】视频或教程链接
      【报错原文】有报错就把整段贴上来，不要只写「报错」

      别人复现你的问题时需要这些信息，缺了通常只能猜。
    TEMPLATE
  },
  {
    name: "模组与资源",
    color: "8E5BD9",
    desc: "模组、光影、材质包推荐与整合包",
    topic_title_placeholder: "模组 / 材质包名 + 版本",
    topic_template: <<~TEMPLATE,
      【名称与版本】
      【安装位置】客户端 / 服务端 / 两边都要
      【下载地址】优先给作者的原发布页，不要只给网盘
      【推荐理由】解决了什么问题，比默认的好在哪
      【注意事项】是否与其他模组冲突、吃不吃配置

      服务器端的改动请先到「白名单与申诉」问一句，别自己装完才发现进不去。
    TEMPLATE
  },
  {
    name: "活动",
    color: "F2A33A",
    desc: "社团活动、比赛与报名",
    topic_title_placeholder: "活动名称 + 日期",
    topic_template: <<~TEMPLATE,
      【活动名称】
      【时间】几月几日 周几 几点到几点
      【地点】服务器内坐标 / 线下地点
      【报名方式】在下面回帖：游戏名（区分大小写）+ 需不需要借用设备
      【注意事项】要自带什么、迟到了怎么加入

      活动前一天会在这里更新一次，报名后记得回来看。
    TEMPLATE
  },
  {
    name: "白名单与申诉",
    color: "3AB7C4",
    desc: "白名单申请、封禁申诉与问题反馈",
    topic_title_placeholder: "【申请】游戏名 或 【申诉】游戏名",
    topic_template: <<~TEMPLATE,
      先删掉用不上的那一段，只留你要办的事。

      ## 申请白名单（第一次进服）

      【游戏名】照你在游戏里输入的写，区分大小写，写错会进不去
      【学号后四位】用来确认是本校同学
      【玩过 Minecraft 吗】新手也欢迎，我们会带你

      ## 申诉与问题反馈

      【游戏名】区分大小写
      【发生了什么】发生时间 + 当时在做什么
      【你希望怎么解决】

      一般 24 小时内有人回复。着急的话在社团群里 @ 管理员，别在这里重复发帖。
    TEMPLATE
  },
  {
    name: "水吧",
    color: "92A1A8",
    desc: "闲聊灌水",
    topic_title_placeholder: "随便起个能看懂的标题",
    topic_template: nil,
  },
  # 信任等级专属版块：达到 2 级才能进入
  {
    name: "老玩家俱乐部",
    color: "B3923A",
    desc: "信任等级 2 及以上可见",
    permissions: {
      trust_level_2: :full,
    },
    topic_title_placeholder: nil,
    topic_template: nil,
  },
]

def create_category(spec)
  category = Category.new(
    name: spec[:name],
    user: Discourse.system_user,
    color: spec[:color],
    text_color: "FFFFFF",
    description: spec[:desc],
  )
  category.set_permissions(spec[:permissions]) if spec[:permissions]
  category.save!
  puts "created category #{spec[:name]}"
  category
end

# 模板写在脚本里而不是后台，重跑脚本就能把模板改回来；
# 所以已存在的版块也要比对一次，不一致就覆盖。
def apply_topic_template(category, spec)
  template_changed = category.topic_template != spec[:topic_template]
  title_placeholder_changed = category.topic_title_placeholder != spec[:topic_title_placeholder]
  unless template_changed || title_placeholder_changed
    puts "category #{category.name} template is up to date"
    return
  end

  category.topic_template = spec[:topic_template]
  category.topic_title_placeholder = spec[:topic_title_placeholder]
  category.save!
  puts "updated template of category #{category.name}"
end

CATEGORIES.each do |spec|
  category = Category.find_by(name: spec[:name]) || create_category(spec)
  apply_topic_template(category, spec)
end
