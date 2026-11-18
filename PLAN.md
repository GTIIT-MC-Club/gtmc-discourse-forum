# GTMC 论坛实施计划

广东以色列理工学院 Minecraft 社团（GTMC）的专用论坛。以 Discourse 为底座，复现 Linux.do 的社区机制
（信任等级、积分、登录中心、外观），并与社团的 Minecraft 服务器打通。

开工前必读：本文件 + `AGENTS.md`（代码规范）。两者冲突时以 `AGENTS.md` 为准。

---

## 0. 已确定的事实与决策

| 项 | 结论 |
|---|---|
| 运行机器 | 社团自有机器：X99 平台、Debian、64G DDR3，在校内（大陆网络），无公网 IP |
| 对外访问 | 境外 VPS 做入口（Caddy 终结 HTTPS），经 frp 转发到自有机器；免备案。有域名、还没有 VPS 时过渡用 Cloudflare Tunnel，见 `infra/README.md` I2.0a |
| 注册 | 仅 `@gtiit.edu.cn` 邮箱；游客可只读公开版块 |
| 规模 | 约 100 人 |
| MC 服务器 | **4 个互相独立的服**（各有地址，无群组代理），全部接入论坛；纯离线模式，没有任何登录插件。其中有 Paper/Purpur，也有 Fabric/Forge 系的模组服，各服的核心和版本待负责人确认（任务 H2）。与论坛在同一台机器的不同虚拟机上（见下文 Proxmox VE） |
| 聊天平台 | Discord |
| 节奏 | 2 周出 MVP（第一期），之后两期迭代 |
| 域名 / VPS / 邮件服务 | 都还没有，需要负责人购买（见任务 H1） |

由这些事实推出的三条硬约束，所有设计都绕不开：

1. **自有机器在大陆，连不上 Discord、Docker Hub，GitHub 不稳定。**
   所以凡是要和 Discord 说话的代码都跑在 VPS 上（`bridge/`），自有机器上的组件只主动连 VPS。
   安装 Discourse 时拉镜像和克隆代码要走 VPS 代理。
2. **离线模式下玩家名可以随便冒用。** 白名单只按名字放行等于没有防护，
   所以进服后必须用论坛发的一次性登录码验证身份（见 4.2）。
3. **流量经过 Caddy 和 frp 两跳。** Discourse 必须从 `X-Forwarded-For` 取真实 IP，否则全站共用一个 IP，
   限流会误伤所有人。

### 不做的事（非目标）

- 不复刻 Linux.do 的具体视觉稿、图标、文案；只借鉴布局和机制。
- 不使用 Mojang 的官方素材（贴图、Logo、Minecraft 字体）。像素风素材自己画或用开源协议的。
- 第三方应用自助注册 OAuth 客户端（Linux.do Connect 有）。v1 的客户端由管理员写配置文件。
- 积分兑换服内奖励。v1 只做积分和排行榜。
- 皮肤头像。离线服拿不到可信的皮肤来源，改为在用户卡片上显示 MC 游戏名。
- QQ 群互通、Folia 支持、Velocity/BungeeCord 群组代理（现在的 4 个服是各自独立的，按独立服支持）。
- 跨服聊天：一个 MC 服里的聊天不转发到其他 MC 服，只转发到 Discord 和论坛（见 4.3）。

---

### Proxmox VE

自有机器跑 Proxmox VE，论坛和 MC 服各在自己的虚拟机里。宿主机配置、存储分工，以及由此带来的装法和网络约束，
见 `infra/README.md` 的「部署前提」。

## 1. 架构

```
                         ┌──────────── 境外 VPS ────────────┐
用户浏览器 ──HTTPS──────▶│ Caddy ─▶ frps ─────────┐         │
                         │   │                     │         │
Discord ◀──────────────▶│   └─▶ bridge (第三期)   │         │
                         └──────────▲──────────────┼─────────┘
                                    │ wss / https  │ frp 隧道
                         ┌──────────┼──────────────▼─────────┐
                         │      自有机器（校内）              │
                         │  frpc ─▶ Discourse 容器 :8880      │
                         │            └ 插件 discourse-gtmc   │
                         │  Paper 服 └ 插件 gtmc-paper ──▶ 论坛 API（本机回环）
                         └────────────────────────────────────┘
```

三个域名（`<domain>` 由负责人定，代码里一律用占位符，不要写死）：

| 占位符 | 例子 | 指向 | 用途 |
|---|---|---|---|
| `FORUM_HOST` | `forum.<domain>` | VPS → frp → Discourse | 论坛 |
| `CONNECT_HOST` | `connect.<domain>` | VPS 上的 bridge | 登录中心、Webhook、MC 插件的 WebSocket |
| `MAP_HOST` | `map.<domain>` | VPS → frp → BlueMap | 实时地图（可选） |

## 2. 仓库结构

GitHub 组织 `GTIIT-MC-Club` 下四个仓库。论坛的主题、插件和教程各自单独成库，是为了让它们走 Discourse
自己的安装和更新机制（插件克隆进 `plugins/`、主题从 Git 安装、后台能看到版本和更新），不必再从总仓库里挑子目录。
各部分自带 README（怎么构建、怎么测、怎么部署），互不引用对方的源码，只通过第 4 节的接口契约通信。

| 仓库 | 内容 | 怎么装到论坛 |
|---|---|---|
| `gtmc-forum-infra`（本仓库） | `PLAN.md`、`AGENTS.md`、部署脚本和配置（`infra/`）、MC 端（`mc-plugin/`）、设计稿（`design/`），以后的 `bridge/` | 在论坛虚拟机上检出，`infra/deploy-discourse.sh` 部署 |
| `gtmc-forum-plugin` | Discourse 插件 `discourse-gtmc`，Ruby + Ember，仓库根目录就是插件根目录 | `app.yml` 的 `after_code` 钩子把它克隆进容器的 `plugins/discourse-gtmc`，重建容器生效 |
| `gtmc-forum-theme` | Discourse 主题 GTMC，仓库根目录就是主题根目录（`about.json` 在根上）；图标精灵 `assets/gtmc-icons.svg` 由仓库里的脚本从 `icons/` 生成并提交 | `infra/discourse/import_theme.rb` 用核心的远程主题从 Git 安装或更新，并设为默认主题、设配色 |
| `gtmc-forum-wiki` | 新手教程（Markdown，一篇一个话题），文件在仓库根目录；`README.md` 是写作约定，不同步 | `deploy-discourse.sh` 在论坛虚拟机上克隆或拉取它，交给 `infra/discourse/guides.rb` 同步成「新人指南」的锁定话题 |

插件内部的名字不变：插件名 `discourse-gtmc`、站点设置前缀 `gtmc_`、装在 `plugins/discourse-gtmc`。
`AGENTS.md` 和第 4 节的接口契约只放在本仓库，另外三个仓库的 README 链接到这里。

本仓库的目录：

```
infra/
  discourse/                  容器配置（app.yml、app.internal.yml）和站点脚本（site_settings.rb、import_theme.rb、
                              sidebar.rb、badges.rb、narrative_bot.rb、guides.rb）
  content/                    置顶帖、引导机器人文案、管理员操作手册 admin-setup.md
  frp/ caddy/ systemd/        入口和隧道
  deploy-discourse.sh         一键部署到论坛虚拟机
  README.md                   部署手册
mc-plugin/                    MC 端接入，Gradle 多项目（第一期起）
  common/                     与平台无关的逻辑：论坛 API 客户端、心跳、进服判定、冻结状态机。
                              只依赖 JDK 和 Gson，编译目标 Java 17（Fabric/Forge 的 1.20.x 服跑在 Java 17 上）
  paper/                      Paper/Purpur 插件 gtmc-paper，Java 21，薄适配层
  fabric/ neoforge/ …         模组端适配层，等 H2 确认各服核心和版本后再建（任务 F1）
design/                       设计稿和品牌素材
bridge/                       Node 22 + TypeScript，跑在 VPS（第三期，待建）
```

**跨仓库的改动按依赖顺序做**：先在本仓库改第 4 节的契约（单独一个 PR，或和第一个实现一起），再按「插件 → 主题 →
本仓库的部署脚本」的顺序在各仓库提 PR，每个 PR 的描述里链接契约的那次改动。主题依赖插件提供的接口和设置，
部署脚本依赖前两者已经合并，所以合并和上线也按这个顺序。

## 3. 分期总览

| 期 | 目标 | 上线标准 |
|---|---|---|
| 一（MVP，2 周） | 论坛可用、好看、能看到服务器状态 | 同学用校园邮箱注册发帖；首页显示在线人数 |
| 二（约 3 周） | 论坛账号 = 游戏身份；积分体系 | 未绑定的人进不了服；冒名者过不了登录码 |
| 三（约 3 周） | 登录中心；论坛 ↔ 游戏 ↔ Discord 聊天互通 | 一个外部小工具能用论坛账号登录；三方消息互通 |

每期结束先让真实用户用一周再开下一期。第二、三期开工前在社团群发 5 题问卷确认优先级。

---

## 4. 接口契约

论坛插件、MC 端、bridge 共用（插件在 `gtmc-forum-plugin` 仓库，契约只写在本节），**改契约必须先改本节再改代码**，跨仓库的顺序见第 2 节。所有 JSON 字段用 `snake_case`。
统一术语见 `AGENTS.md` 的术语表。

### 4.1 论坛插件 `discourse-gtmc` 的 HTTP 接口

前缀 `/gtmc`。两类调用方：

- **用户接口**：浏览器里的登录用户，走 Discourse 正常的会话和 CSRF。
- **服务器接口**（`/gtmc/server/*`）：MC 插件和 bridge 调用，用 Discourse 原生 API Key
  （请求头 `Api-Key` + `Api-Username: system`）。插件用 `add_api_key_scope` 注册一个 `gtmc:server` 作用域，
  发给 MC 插件的 Key 只勾这个作用域。
  请求体一律 JSON（`Content-Type: application/json`），数值字段必须是 JSON 数字而不是字符串，否则 400。
- **多服**：每个 MC 服有一个 `server_id`（`^[a-z0-9-]{1,32}$`，如 `survival`），写在该服的插件配置里。
  论坛只认站点设置 `gtmc_servers` 里登记过的 `server_id`，没登记的请求一律返回 `{status: "unknown_server"}`。
  4 个服共用一个 `gtmc:server` Key 即可：Key 只证明「这是我们的服」，`server_id` 只用于区分是哪个服，不用于授权。

服务器接口的业务结论一律用 **HTTP 200 + `status` 枚举**表达，4xx/5xx 只表示请求本身有问题。
这样调用方能把「论坛说不行」和「论坛挂了」分开处理。

| 方法 路径 | 调用方 | 期 | 请求 | 响应 |
|---|---|---|---|---|
| `GET /gtmc/status.json` | 任何人 | 一 | — | `{refresh_interval_seconds, servers: [{server_id, name, address, map_url, icon, color, online, version, players_online, players_max, players, tps, updated_at}]}`，规则见表下 |
| `GET /gtmc/newcomer_guide.json` | 任何人 | 一 | — | `{topic_url, read}`：置顶的「新人指南」帖的地址（找不到或当前用户看不见则为 `null`）、当前登录用户是否读过它（游客恒为 `false`）。右栏「新人进服」面板用它判断第二步 |
| `POST /gtmc/server/heartbeat.json` | MC 插件 | 一 | `{server_id, version, players_online, players_max, player_names[], tps}` | `{status: "ok"}` 或 `{status: "unknown_server"}`；缺 `server_id` 或它不是字符串属于请求本身有问题，返回 400 |
| `GET /gtmc/account.json` | 用户 | 二 | — | `{mc_name}`（未绑定为 `null`），`{renamable_at}` |
| `PUT /gtmc/account.json` | 用户 | 二 | `{mc_name}` | 成功同上；不合法或被占用返回 422 和可读的中文原因 |
| `DELETE /gtmc/account.json` | 用户 | 二 | — | 204 |
| `POST /gtmc/login_code.json` | 用户 | 二 | — | `{code, expires_in_seconds}`；每用户每分钟最多 5 次 |
| `GET /gtmc/server/players/:mc_name.json?ip=` | MC 插件 | 二 | — | 见下 |
| `POST /gtmc/server/sessions.json` | MC 插件 | 二 | `{mc_name, code, ip}` | `{status: "ok", trusted_until}` 或 `{status: "invalid_code"}` 或 `{status: "too_many_attempts"}` |
| `GET /gtmc/server/users/:user_id.json` | bridge | 三 | — | `{user_id, username, mc_name, trust_level}` |

`GET /gtmc/status.json` 的响应规则：

- `refresh_interval_seconds` 固定 30，与 MC 插件默认的心跳间隔一致；前端的轮询周期和刷新圆环都取它。
- `servers` 已排好序：在线的在前、按 `players_online` 从多到少，离线的按 `gtmc_servers` 的顺序。
- 某服超过 `gtmc_heartbeat_timeout_seconds` 没收到心跳则该项 `online: false`，`version` 起的字段为 `null`。
- `players` 是 `[{mc_name, avatar_template}]`：**只对登录用户返回**，游客拿到 `null`（人数照常返回）；`avatar_template` 在 P2 绑定前用游戏名生成字母头像，绑定后用对应论坛账号的头像。

`GET /gtmc/server/players/:mc_name.json` 的 `status`：

| status | 含义 | 附带字段 | MC 插件的动作 |
|---|---|---|---|
| `allowed` | 已绑定且账号正常 | `mc_name`（规范大小写）、`user_id`、`username`、`trust_level`、`ip_trusted` | 放行；`ip_trusted` 为假则进服后冻结等登录码 |
| `unbound` | 没有论坛账号绑定这个名字 | — | 踢出，提示去论坛绑定 |
| `case_mismatch` | 名字对但大小写不同 | `mc_name`（规范大小写） | 踢出，提示正确写法（离线 UUID 由名字的精确大小写决定） |
| `suspended` | 论坛账号被封禁或禁言 | `reason` | 踢出，显示原因 |

数据与规则：

- 绑定存在表 `gtmc_minecraft_accounts`（`user_id` 唯一、`mc_name`、`mc_name_lower` 唯一索引、时间戳）。
  唯一性靠数据库索引保证，不靠先查后写。
- `mc_name` 必须匹配 `^[A-Za-z0-9_]{3,16}$`。改名有冷却期（`gtmc_rename_cooldown_days`，默认 30）。
- 登录码：6 位数字，存在 Redis，有效期 `gtmc_login_code_ttl_seconds`（默认 300），用一次即删。
  比较用常数时间比较。同一 `mc_name` 10 分钟内最多试 5 次。
- IP 信任：登录码验证成功后，记住 `(user_id, ip)`，有效期 `gtmc_ip_trust_hours`（默认 12，设 0 关闭）。
  存 Redis，丢了只是让玩家重新输一次码。**校园网多人共用出口 IP，这个时长不要调大。**
- 服务器状态：每个服最近一次心跳各存一个 Redis 键（键名含 `server_id`）。
- 绑定、登录码、IP 信任都是**全站共享**的：一个游戏名绑定一次，4 个服通用；在任一服输过登录码后，
  同一 IP 在信任期内进任何一个服都免码。

站点设置（都以 `gtmc_` 开头）：`gtmc_enabled`、`gtmc_ip_trust_hours`、`gtmc_login_code_ttl_seconds`、
`gtmc_rename_cooldown_days`、`gtmc_heartbeat_timeout_seconds`（默认 90）、`gtmc_servers`、`gtmc_rail_visible_servers`（默认 3，右栏「服务器」面板默认展开的服数量，其余折叠）、`gtmc_announcement_category`（右栏「公告」面板读的版块，由 `infra/discourse/sidebar.rb` 写入）。

`gtmc_servers` 登记所有服，每项六个字段：`server_id`、`name`（展示名，如「生存服」）、`icon`（图标名，`gtmc-` 开头的主题像素图标或 Font Awesome 图标）、`color`（图标颜色，`#RRGGBB` 格式，可空，空则用主题强调色）、`address`（玩家连接用的地址，展示用）、
`map_url`（可空，空则不显示地图入口；`status.json` 里空的 `map_url` 返回 `null`）。优先用 Discourse 的 `type: objects` 结构化设置（带 schema）；
当前版本不支持就用 `type: list`，每项写成 `server_id|name|address|map_url`。实现前查 Discourse 源码确认，
并在插件 README 里写明管理员怎么填。`icon` 用 `type: icon`（后台是图标选择器，`gtmc-*` 主题图标和 Font Awesome 图标都能选）；`server_id`、`icon`、`color` 的格式 schema 管不了，插件读取时检查，不合格的项被忽略（和 `server_id` 重复、格式不对一样）。原来的 `gtmc_server_address`、`gtmc_map_url` 两个设置删掉。

### 4.2 玩家进服流程（第二期的核心）

```
玩家连接
  └ 登录前事件（Paper 是 AsyncPlayerPreLoginEvent，模组端用各自加载器的对应事件）：查 /gtmc/server/players/<名字>?ip=<IP>
       ├ unbound / case_mismatch / suspended → 踢出并说明
       ├ 论坛不可达 → 该玩家在本地缓存里且上次是 allowed 则放行（按未信任处理），否则踢出
       └ allowed
            ├ ip_trusted = true  → 正常进服
            └ ip_trusted = false → 进服但冻结
                                   └ 玩家在论坛「我的 MC 账号」页点「获取登录码」
                                   └ 游戏里输入 /login <登录码>
                                        ├ ok → 解冻
                                        └ invalid_code → 提示重试；120 秒内未通过则踢出
```

冻结状态下：不能移动、聊天、破坏、放置、交互、受伤、捡拾和丢弃物品、打开容器；
除 `/login` 外的命令全部拦截；聊天栏每 10 秒提示一次怎么获取登录码。

所有 HTTP 调用都不许在主线程上做。判定和冻结的规则写在 `mc-plugin/common` 里，各平台只负责把事件接进来、把动作执行出去，
这样 4 个服的行为一致。

### 4.3 bridge 的接口（第三期）

| 接口 | 说明 |
|---|---|
| `GET /healthz` | 存活检查 |
| `/oidc/*` | 标准 OpenID Connect。`issuer` 为 `https://CONNECT_HOST/oidc` |
| `POST /webhooks/discourse` | 接 Discourse Webhook，校验 `X-Discourse-Event-Signature`（HMAC-SHA256），校验失败返回 401 |
| `GET /mc`（WebSocket） | MC 插件主动连入，请求头 `Authorization: Bearer <token>` |

WebSocket 消息（双向，同一格式）：

```json
{"type": "chat", "source": "minecraft", "server_id": "survival", "author": "Steve", "text": "有人在线吗"}
{"type": "announcement", "text": "新帖：周末建筑比赛报名", "url": "https://FORUM_HOST/t/123"}
```

`source` 取值 `minecraft` / `discord` / `forum`。`server_id` 只在 `source` 为 `minecraft` 时出现。
转发规则：MC 服的消息发到 Discord 和论坛（带服名前缀，如 `[生存服] Steve: …`），不发到其他 MC 服；
Discord 和论坛的消息、以及 `announcement`，广播到所有在线的 MC 服。每个 MC 服各自建一条 WebSocket 连接。
防回环：各端忽略自己的机器人账号发出的消息。

OIDC 的用户身份来自论坛：bridge 在登录交互里把用户重定向到论坛的 DiscourseConnect Provider
（`/session/sso_provider`），拿回签名的用户信息。ID Token 的声明：`sub`（论坛用户 ID）、
`preferred_username`、`name`、`email`、`picture`、`groups`、`trust_level`、`minecraft_name`。

---

## 5. 第一期任务（MVP）

标 **H** 的任务只能由负责人本人做（花钱、实名、收验证码）。
每个任务一个分支、一个 PR，做完对照验收标准自测，并在 PR 里贴出验证过程的真实输出。

### H1 采购与账号（负责人）

- 买域名，DNS 托管到任意服务商，建好三个子域名的 A 记录指向 VPS。
- 买境外 VPS（香港或日本优先，1 核 1G、Debian 12 即可）。
- 注册事务邮件服务（Resend 或 Brevo），按它的指引给域名加 SPF/DKIM 记录，拿到 SMTP 凭据。
- 把凭据放进自有机器的 `app.yml`（不进仓库）。

### H2 各服清单（负责人）

列出 4 个服各自的 `server_id`、展示名、核心（Paper/Purpur/Fabric/Forge/NeoForge）、MC 版本、Java 版本、玩家连接地址。F1 等它。

### I1 VPS 入口

- 装 frps（配置用 `infra/frp/frps.toml`）和 Caddy，都用 systemd 管理。
- 写 `infra/caddy/Caddyfile`：`FORUM_HOST` 反代到 `127.0.0.1:8880`。Caddy 默认会带上
  `X-Forwarded-For` 和 `X-Forwarded-Proto`，不要去掉。
- 防火墙只放行 22、80、443、7000。
- 装一个只监听回环的 HTTP 代理（如 tinyproxy），供自有机器经 SSH 隧道使用（I2 要用）。
- **验收**：`curl -I https://FORUM_HOST` 拿到有效证书（后端没起时 502 属正常）；从外网扫不到 8880 和代理端口。

### I2 自有机器安装 Discourse

- 装 Docker。给 Docker 守护进程、git、以及 Discourse 构建容器配上经 VPS 的代理
  （SSH 本地转发到 I1 的代理；构建容器访问不到宿主机回环，代理要监听在 docker 网桥地址上）。
- 写 `infra/frp/frpc.toml`：把本机 `127.0.0.1:8880` 映射到 VPS 的 8880，开启 TLS，用 token 认证；systemd 管理。
- 按官方方式克隆 `discourse_docker` 到 `/var/discourse`，放入 `infra/discourse/app.yml` 并填好占位符，`./launcher rebuild app`。
- **验收**：重建全程无错；浏览器打开 `https://FORUM_HOST` 看到 Discourse；机器重启后 frpc 和论坛都自动恢复。

### I3 上线前验证

- 执行 `infra/discourse/site_settings.rb`（用法在文件头）。有设置名报错就查当前版本的正确名字并修脚本，不许删掉了事。
- 真实 IP：从两个不同网络访问，在管理后台的用户页确认记录到的是各自的公网 IP，而不是 `172.x`。
  `app.yml` 里那段 nginx 替换规则没在真机上跑过，不生效就对着容器里的
  `/etc/nginx/conf.d/discourse.conf` 修正。
- 邮件：用一个真实的 `@gtiit.edu.cn` 邮箱注册，确认激活信进了收件箱而不是垃圾箱或被隔离。
  **这一条不过，MVP 不能上线**；进垃圾箱就先查 SPF/DKIM/DMARC，再考虑换服务商。
- 用非校园邮箱注册，确认被拒绝。
- 手动触发一次备份并确认文件生成；把备份目录同步到另一块盘或 VPS 的方案写进 `infra/README.md`。
- **验收**：以上每条在 `infra/README.md` 里留下可复现的步骤。

### F1 模组端适配（等 H2）

- 按 H2 的结果为每种模组加载器建一个 `mc-plugin/<加载器>/` 子项目，复用 `common/`。先做心跳，进服验证随第二期一起做。
- 冻结在模组端要靠加载器的事件或 Mixin 实现，难度比 Paper 高。每种加载器开工前先写一页调研：
  哪些冻结行为能用现成事件拦住，哪些必须 Mixin，然后再写代码。

### 第一期完成标准

5 位社团成员从注册到发出第一帖全程无人指导、无报错；首页状态组件工作正常；备份每天生成。

---

## 6. 第二期任务

### P2 账号绑定

- 迁移建表 `gtmc_minecraft_accounts`；实现 `/gtmc/account.json` 三个接口。
- 用户偏好设置里加「我的 MC 账号」页：绑定、改名（显示冷却剩余时间）、解绑。
- 用户卡片和个人主页显示 MC 游戏名（只加到用户卡片的序列化器，不加到帖子序列化器，避免 N+1）。
- **验收**：rspec 覆盖非法名字、大小写不同的重名、并发重复绑定（靠唯一索引报错）、冷却期。

### P3 登录码与进服判定

- 实现 `/gtmc/login_code.json`、`/gtmc/server/players/:mc_name.json`、`/gtmc/server/sessions.json`。
- 「我的 MC 账号」页加「获取登录码」按钮，大字显示登录码和倒计时。
- **验收**：rspec 覆盖 4.1 表里的每个 `status`、登录码过期、重复使用、尝试次数超限、IP 信任到期。

### M2 进服闸门

- 按 4.2 实现预登录检查，包括论坛不可达时的本地缓存放行（缓存落盘，重启不丢）。
- 踢出信息用中文，说清原因和下一步（附论坛地址）。
- **验收**：未绑定、大小写不符、被封禁三种情况的踢出文案都正确；拔掉论坛后老玩家仍能进服。

### M3 冻结与 `/login`

- 按 4.2 实现冻结和 `/login <登录码>`。
- **验收**：冻结期间逐项确认 4.2 列出的行为都被拦住；用别人的名字进服，没有登录码则 120 秒后被踢。

### G1 积分

- 启用随核心捆绑的 gamification 插件，配置计分规则（发帖、被赞、每日访问等）和排行榜，设置写进 `site_settings.rb`。
- 侧边栏加排行榜入口；主题里给排行榜页做样式。
- **验收**：测试账号做相应动作后分数按规则变化。

### 第二期完成标准

关闭原版白名单后，只有绑定了论坛账号的人能进服；找一位同学尝试冒用他人名字，确认进不去。

---

## 7. 第三期任务

### B1 bridge 骨架与部署

- 建 `bridge/`：Node 22、TypeScript 严格模式、`/healthz`、配置从环境变量读（启动时校验，缺了直接报错退出）。
- systemd 单元和 Caddy 的 `CONNECT_HOST` 反代，写进 `infra/`。
- **验收**：`curl https://CONNECT_HOST/healthz` 返回 200；进程崩溃后自动重启。

### B2 登录中心（OIDC）

- 用 `oidc-provider` 库，不自己实现协议。持久化用 SQLite；签名密钥首次启动生成并落盘。
- 登录交互按 4.3 走论坛的 DiscourseConnect Provider；`minecraft_name` 从 `/gtmc/server/users/:user_id.json` 取。
- 客户端列表写在一个配置文件里，README 写清怎么加一个客户端。
- **验收**：用一个现成的 OIDC 调试客户端走通授权码流程，ID Token 里的声明齐全；
  篡改 DiscourseConnect 返回的签名会被拒绝。

### B3 Discord 与消息中枢

- Discord 机器人（`discord.js`）绑定一个频道；向 Discord 发消息用频道 Webhook，以便显示发言者的名字。
- 论坛侧：接 Discourse 的聊天消息 Webhook；向论坛聊天频道发消息走 Chat 的 API。
  这两处的具体事件名和路径以运行中的实例为准，先核实再写。
- 按 4.3 的规则在三端之间转发，并做防回环。
- **验收**：三端各发一条，另外两端各只收到一次；bridge 重启后自动恢复。

### M4 游戏内聊天接入

- MC 插件用 JDK 的 WebSocket 客户端连 `wss://CONNECT_HOST/mc`，断线指数退避重连（上限 60 秒）。
- 上行玩家聊天；下行消息按来源加前缀和颜色广播。
- **验收**：bridge 停机期间游戏内聊天完全正常，恢复后自动重连。

### B4 新帖推送

- 接 Discourse 的新话题 Webhook，向 Discord 发卡片、向游戏内发 `announcement`。只推公开版块的帖子。
- **验收**：在受限版块发帖不会被推送。

---

## 8. 风险清单

| 风险 | 影响 | 应对 |
|---|---|---|
| 校园邮箱拦截激活信 | 没人能注册 | I3 第一时间实测；备选方案是换邮件服务商，或请学校 IT 加白 |
| 自有机器构建时拉不到镜像和代码 | 装不上、升不了级 | I2 的代理方案；升级前先确认代理可用 |
| VPS 或 frp 断线 | 论坛对外不可达 | systemd 自动重启；MC 进服走本机回环，不受影响 |
| 自有机器断电或硬盘损坏 | 数据丢失 | 每日备份并异机存放（I3） |
| 校园网共用出口 IP | IP 信任期内同出口的人可冒名 | 信任期默认 12 小时且可设为 0；在规则帖里说明 |
| Discourse 升级改了内部接口 | 自写插件失效 | 只用公开的插件 API；每个接口都有 rspec；升级前先在测试实例跑一遍测试 |
