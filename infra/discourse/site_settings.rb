# 站点设置与版块初始化，可重复执行。
# 用法（在自有机器上）：
#   docker cp site_settings.rb app:/tmp/ && docker exec -u discourse -w /var/www/discourse app \
#     bundle exec rails runner /tmp/site_settings.rb
# 设置名写错会直接报错退出，不会静默跳过。

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

  # 备份：每天一次，保留 7 份（存在 /var/discourse/shared/standalone/backups）
  backup_frequency: 1,
  maximum_backups: 7,
}

SETTINGS.each do |name, value|
  SiteSetting.set(name, value)
  puts "set #{name} = #{value}"
end

# 版块。permissions 为 nil 表示所有人可见；否则按用户组限制。
CATEGORIES = [
  { name: "公告", color: "E45735", desc: "社团与服务器公告", permissions: { everyone: :readonly, staff: :full } },
  { name: "建筑展示", color: "5DBB47", desc: "晒出你的建筑、存档截图与巡礼" },
  { name: "红石与技术", color: "D0312D", desc: "红石机器、生电、命令方块与数据包" },
  { name: "模组与资源", color: "8E5BD9", desc: "模组、光影、材质包推荐与整合包" },
  { name: "活动", color: "F2A33A", desc: "社团活动、比赛与报名" },
  { name: "白名单与申诉", color: "3AB7C4", desc: "白名单申请、封禁申诉与问题反馈" },
  { name: "水吧", color: "92A1A8", desc: "闲聊灌水" },
  # 信任等级专属版块：达到 2 级才能进入
  { name: "老玩家俱乐部", color: "B3923A", desc: "信任等级 2 及以上可见", permissions: { trust_level_2: :full } },
]

CATEGORIES.each do |spec|
  category = Category.find_by(name: spec[:name])
  if category.nil?
    category = Category.new(name: spec[:name], user: Discourse.system_user,
                            color: spec[:color], text_color: "FFFFFF",
                            description: spec[:desc])
    category.set_permissions(spec[:permissions]) if spec[:permissions]
    category.save!
    puts "created category #{spec[:name]}"
  else
    puts "category #{spec[:name]} exists, skipped"
  end
end
