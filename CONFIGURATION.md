# 论坛的配置在哪里

接手的人先读这一篇：论坛上每一样东西由谁管、存在哪、改了以后怎么上线、怎么备份和回档。
命令前的 `PC$` 表示在自己电脑上的仓库检出里执行，`HOME$` 表示在论坛虚拟机上执行（同 `infra/README.md`）。

**总原则：代码归仓库，设置归论坛。**

- 插件和主题是代码，以 GitHub 仓库为准，合并到 `main` 再部署就会上线。
- 论坛设置（站点设置、版块、侧边栏、徽章、文本……）以论坛后台为准，管理员直接在后台改。
  仓库里的 `forum-config/` 只是它的**备份**：管理员手动导出、提交，出了问题时照着回档。
  部署脚本不会拿仓库的值覆盖后台。

## 1. 三个仓库

| 仓库 | 装的是什么 | 怎么上线 |
|---|---|---|
| `gtmc-forum-infra`（本仓库） | 部署脚本、容器配置、新站初始化脚本、`forum-config/` 设置备份、MC 插件、设计稿 | 在论坛虚拟机上跑 `sudo infra/deploy-discourse.sh` |
| `gtmc-forum-plugin` | Discourse 插件 `discourse-gtmc`：服务器状态、右栏面板、心跳接口 | 合并后 `sudo infra/deploy-discourse.sh --rebuild`（重建容器时克隆） |
| `gtmc-forum-theme` | Discourse 主题 GTMC：样式、图标、配色、页脚 | 合并后跑部署脚本（每次都会从 GitHub 更新），或后台「外观 → 主题 → 检查更新」 |

插件和主题本身是代码，但**它们的设置是论坛设置**：插件的设置（`gtmc_servers` 等）是站点设置的一部分，
主题的设置（Discord 邀请链接、页脚链接）存在论坛数据库里。两者都在后台改，都由 `forum-config/` 备份。

## 2. 论坛上的东西归谁管

| 东西 | 以谁为准 | 在哪改 | 备份在 |
|---|---|---|---|
| 站点设置（含插件设置） | 论坛 | 后台「设置」 | `forum-config/site_settings.yml` |
| 主题设置、默认主题、配色选择 | 论坛 | 后台「外观 → 主题」 | `forum-config/themes.yml` |
| 配色的色值 | 论坛（初始值来自主题仓库） | 后台「外观 → 配色」 | `forum-config/color_schemes.yml` |
| 版块：名字、简介、颜色、图标、顺序、权限、发帖模板 | 论坛 | 版块的「编辑」 | `forum-config/categories.yml` |
| 侧边栏「社区」区的链接 | 论坛 | 侧边栏「社区」旁的铅笔 | `forum-config/sidebar.yml` |
| 徽章 | 论坛 | 后台「徽章」 | `forum-config/badges.yml` |
| 群组的设置（不含成员） | 论坛 | 「群组」 | `forum-config/groups.yml` |
| 文本覆盖：小火把的台词、徽章的中文名等 | 论坛 | 后台「自定义 → 文本」 | `forum-config/text_overrides.yml` |
| 用户字段 | 论坛 | 后台「用户字段」 | `forum-config/user_fields.yml` |
| Logo、图标图片 | 论坛 | 后台「设置 → 品牌」 | 只备份地址；源文件在 `design/brand/` |
| 帖子、用户、私信 | 论坛 | — | 不在仓库里，靠论坛自己的备份（见第 6 节） |
| 域名、发信账号、容器配置 | 虚拟机上的文件 | 见第 5 节 | 不进仓库（含密码） |

## 3. 部署做什么、不做什么

`sudo infra/deploy-discourse.sh` 每次都做：

1. 拉取本仓库的最新 `main`；
2. 生成容器配置，内容变了（或传了 `--rebuild`）就重建容器，重建时重新克隆插件；
3. 从 GitHub 更新 GTMC 主题的代码（主题设置不动）。

它**不会**修改任何论坛设置。唯一的例外是新站：

### 新站初始化（只发生一次）

数据库里没有初始化标记时（全新安装的论坛），部署脚本先依次跑 `infra/discourse/` 下的初始化脚本，
把论坛设成社团的样子，然后写下标记。之后再部署，这些脚本一律跳过。

| 顺序 | 脚本 | 初始化什么 |
|---|---|---|
| 1 | `site_settings.rb` | 站点设置、九个版块和发帖模板、信任等级门槛 |
| 2 | `import_theme.rb` | 安装 GTMC 主题，第一次安装时设为默认主题和两套配色 |
| 3 | `sidebar.rb` | 版块顺序和图标、默认侧边栏、「社区」区链接、页脚链接 |
| 4 | `badges.rb` | 「社团成就」徽章和核心徽章的中文名 |
| 5 | `narrative_bot.rb` | 引导机器人小火把的名字、头像和台词 |

这些脚本是「新站的出厂设置」，**不是**线上设置的记录：站点初始化以后，后台改了什么它们都不知道。
线上现在是什么样，以 `forum-config/` 的最新备份为准。

标记存在论坛数据库（`PluginStore` 的 `gtmc_infra / initialized_at`），跟着数据走：从备份恢复的站点也带着它，
不会被重新初始化。部署脚本读不出标记时直接停下，不会猜。

## 4. 备份到 GitHub

改完后台设置，在**自己电脑上**的本仓库检出里导出、检查、提交（论坛虚拟机没有推送 GitHub 的权限，
推送用的是你自己的 GitHub 账号）。参数是论坛虚拟机的 SSH 地址，那个用户要在 `docker` 组里：

```
PC$ infra/export-forum-config.sh gtmc@gtmc-forum   # 导出到 forum-config/，并列出改了哪些文件
PC$ git diff forum-config                          # 逐项确认都是有意的改动
PC$ git add forum-config && git commit -m "chore(config): back up forum settings" && git push
```

导出只读论坛，不改任何东西，可以随时跑。文件按名字排序、不含 id 和时间，没改设置时导出结果不变，
所以 `git diff` 里出现的每一行都是真实的改动，`git log forum-config` 就是设置的修改历史。

本仓库是**公开**的，导出时跳过密钥类的设置：核心标成 secret 的，以及名字里带 `secret`、`password`、`token`、
`api_key`、`private_key`、`credentials` 的。它们丢了要重新到对应平台生成。其余设置（包括 MC 服的内网地址）
都会进仓库，不想公开的东西不要写进论坛设置。

## 5. 不在论坛后台的配置

这些在论坛虚拟机（`100 gtmc-forum`）上，改完重跑部署脚本生效：

| 文件 | 管什么 | 进不进仓库 |
|---|---|---|
| `infra/discourse/app.internal.yml`（现在用的）、`app.yml`（有 VPS 之后用） | 容器：端口、插件、内存 | 进仓库 |
| 部署时传的 `GTMC_FORUM_HOST` | 论坛域名 | 不进仓库，见 `infra/README.md` |
| `/etc/gtmc/smtp.env` | 发信账号和密码 | 不进仓库，格式见 `infra/README.md`「发信」 |
| `cloudflared` 服务 | 对外入口（Cloudflare Tunnel） | 不进仓库，见 `infra/README.md` I2.0a |

## 6. 回档

先想清楚要回到哪一步：只是某个设置改错了，还是整个论坛坏了。

**某几项设置改错了**：在 GitHub 上看 `forum-config/` 的历史，找到改错前的值。

- 站点设置可以整份导回。用的是核心自带的任务，只改和文件不一样的项，并逐项打印改了什么。在自己电脑上：

  ```
  PC$ git show <改错之前的提交>:forum-config/site_settings.yml |
        ssh gtmc@gtmc-forum 'docker exec -i -u discourse -w /var/www/discourse app bundle exec rake site_settings:import'
  ```

- 其余几类（版块、主题设置、侧边栏、徽章、文本……）核心没有可靠的导入工具，照备份里的值在后台改回去。
  文件里每一项的字段名和后台表单一一对应。

**整个论坛坏了**（误删版块、数据出错、升级失败）：用论坛自己的备份恢复。论坛每天自动备份一次，保留 7 份，
包含数据库和上传的图片，存在 `/var/discourse/shared/standalone/backups/default/`。
后台「备份」页可以下载和恢复，恢复会让论坛回到备份那一刻，之后发的帖子会丢，动手前先在「公告」里说一声。

**恢复备份之后、再部署之前，先确认初始化标记还在**。2026-11-18 之前的备份里没有这个标记，
用它们恢复后直接部署，部署脚本会把站点当成新站重新初始化，覆盖掉恢复回来的设置：

```
HOME$ docker exec -u discourse -w /var/www/discourse app bundle exec rails runner \
        'p PluginStore.get("gtmc_infra", "initialized_at")'
# 打印 nil 就补上：
HOME$ docker exec -u discourse -w /var/www/discourse app bundle exec rails runner \
        'PluginStore.set("gtmc_infra", "initialized_at", Time.now.utc.iso8601)'
```

恢复之后再导出一次 `forum-config/`，和仓库里的备份对一下差异。

**换一台机器从零重建**：按 `infra/README.md` 装好 Docker 和 Discourse，然后二选一：

- 有论坛备份：先用 `sudo infra/deploy-discourse.sh --no-scripts` 把容器起来（不初始化），再恢复备份
  （新站还没有管理员账号，所以在容器里用命令行：`./launcher enter app` 后 `discourse enable_restore`、
  `discourse restore <备份文件名>`），按上面检查初始化标记，然后正常跑一次部署脚本更新主题；
- 没有备份：直接跑部署脚本，新站会按第 3 节初始化成出厂设置，再照 `forum-config/` 把设置在后台改回来。
