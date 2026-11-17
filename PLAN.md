# GTMC 论坛实施计划

广东以色列理工学院 Minecraft 社团（GTMC）的专用论坛。以 Discourse 为底座，复现 Linux.do 的社区机制
（信任等级、积分、登录中心、外观），并与社团的 Minecraft 服务器打通。

开工前必读：本文件 + `AGENTS.md`（代码规范）。两者冲突时以 `AGENTS.md` 为准。

---

## 0. 已确定的事实与决策

| 项 | 结论 |
|---|---|
| 运行机器 | 社团自有机器：X99 平台、Debian、64G DDR3，在校内（大陆网络），无公网 IP |
| 对外访问 | 境外 VPS 做入口（Caddy 终结 HTTPS），经 frp 转发到自有机器；免备案 |
| 注册 | 仅 `@gtiit.edu.cn` 邮箱；游客可只读公开版块 |
| 规模 | 约 200 人 |
| MC 服务器 | Paper/Purpur 1.21.x，纯离线模式，目前没有任何登录插件；与论坛在同一台机器 |
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
- QQ 群互通、Folia 支持、多子服（群组服）支持。

---

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

单仓库，五个互相独立的部分。每个部分自带 README（怎么构建、怎么测、怎么部署），互不引用对方的源码，
只通过第 4 节的接口契约通信。

```
infra/
  discourse/app.yml           已有，未在真机验证
  discourse/site_settings.rb  已有，未在真机验证
  frp/frps.toml               已有
  frp/frpc.toml               待写（I2）
  caddy/Caddyfile             待写（I1）
  README.md                   部署手册，待写（I1–I3 边做边写）
theme/                        Discourse 主题（第一期）
plugins/discourse-gtmc/       Discourse 插件，Ruby + Ember（第一期起）
mc-plugin/                    Paper 插件 gtmc-paper，Java 21（第一期起）
bridge/                       Node 22 + TypeScript，跑在 VPS（第三期）
```

## 3. 分期总览

| 期 | 目标 | 上线标准 |
|---|---|---|
| 一（MVP，2 周） | 论坛可用、好看、能看到服务器状态 | 同学用校园邮箱注册发帖；首页显示在线人数 |
| 二（约 3 周） | 论坛账号 = 游戏身份；积分体系 | 未绑定的人进不了服；冒名者过不了登录码 |
| 三（约 3 周） | 登录中心；论坛 ↔ 游戏 ↔ Discord 聊天互通 | 一个外部小工具能用论坛账号登录；三方消息互通 |

每期结束先让真实用户用一周再开下一期。第二、三期开工前在社团群发 5 题问卷确认优先级。

---

## 4. 接口契约

三个代码库共用，**改契约必须先改本节再改代码**。所有 JSON 字段用 `snake_case`。
统一术语见 `AGENTS.md` 的术语表。

### 4.1 论坛插件 `discourse-gtmc` 的 HTTP 接口

前缀 `/gtmc`。两类调用方：

- **用户接口**：浏览器里的登录用户，走 Discourse 正常的会话和 CSRF。
- **服务器接口**（`/gtmc/server/*`）：MC 插件和 bridge 调用，用 Discourse 原生 API Key
  （请求头 `Api-Key` + `Api-Username: system`）。插件用 `add_api_key_scope` 注册一个 `gtmc:server` 作用域，
  发给 MC 插件的 Key 只勾这个作用域。
  请求体一律 JSON（`Content-Type: application/json`），数值字段必须是 JSON 数字而不是字符串，否则 400。

服务器接口的业务结论一律用 **HTTP 200 + `status` 枚举**表达，4xx/5xx 只表示请求本身有问题。
这样调用方能把「论坛说不行」和「论坛挂了」分开处理。

| 方法 路径 | 调用方 | 期 | 请求 | 响应 |
|---|---|---|---|---|
| `GET /gtmc/status.json` | 任何人 | 一 | — | `{online, version, players_online, players_max, player_names[], tps, updated_at}`；超过 `gtmc_heartbeat_timeout_seconds` 没收到心跳则 `online: false`，其余字段为 `null` |
| `POST /gtmc/server/heartbeat.json` | MC 插件 | 一 | `{version, players_online, players_max, player_names[], tps}` | `{status: "ok"}` |
| `GET /gtmc/account.json` | 用户 | 二 | — | `{mc_name}`（未绑定为 `null`），`{renamable_at}` |
| `PUT /gtmc/account.json` | 用户 | 二 | `{mc_name}` | 成功同上；不合法或被占用返回 422 和可读的中文原因 |
| `DELETE /gtmc/account.json` | 用户 | 二 | — | 204 |
| `POST /gtmc/login_code.json` | 用户 | 二 | — | `{code, expires_in_seconds}`；每用户每分钟最多 5 次 |
| `GET /gtmc/server/players/:mc_name.json?ip=` | MC 插件 | 二 | — | 见下 |
| `POST /gtmc/server/sessions.json` | MC 插件 | 二 | `{mc_name, code, ip}` | `{status: "ok", trusted_until}` 或 `{status: "invalid_code"}` 或 `{status: "too_many_attempts"}` |
| `GET /gtmc/server/users/:user_id.json` | bridge | 三 | — | `{user_id, username, mc_name, trust_level}` |

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
- 服务器状态：最近一次心跳存 Redis。

站点设置（都以 `gtmc_` 开头）：`gtmc_enabled`、`gtmc_ip_trust_hours`、`gtmc_login_code_ttl_seconds`、
`gtmc_rename_cooldown_days`、`gtmc_heartbeat_timeout_seconds`（默认 90）、`gtmc_server_address`（展示用）、
`gtmc_map_url`（空则不显示地图入口）。

### 4.2 玩家进服流程（第二期的核心）

```
玩家连接
  └ AsyncPlayerPreLoginEvent：查 /gtmc/server/players/<名字>?ip=<IP>
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

所有 HTTP 调用都不许在主线程上做。

### 4.3 bridge 的接口（第三期）

| 接口 | 说明 |
|---|---|
| `GET /healthz` | 存活检查 |
| `/oidc/*` | 标准 OpenID Connect。`issuer` 为 `https://CONNECT_HOST/oidc` |
| `POST /webhooks/discourse` | 接 Discourse Webhook，校验 `X-Discourse-Event-Signature`（HMAC-SHA256），校验失败返回 401 |
| `GET /mc`（WebSocket） | MC 插件主动连入，请求头 `Authorization: Bearer <token>` |

WebSocket 消息（双向，同一格式）：

```json
{"type": "chat", "source": "minecraft", "author": "Steve", "text": "有人在线吗"}
{"type": "announcement", "text": "新帖：周末建筑比赛报名", "url": "https://FORUM_HOST/t/123"}
```

`source` 取值 `minecraft` / `discord` / `forum`。bridge 把一条消息转发到除来源外的另外两端。
防回环：各端忽略自己的机器人账号发出的消息。

OIDC 的用户身份来自论坛：bridge 在登录交互里把用户重定向到论坛的 DiscourseConnect Provider
（`/session/sso_provider`），拿回签名的用户信息。ID Token 的声明：`sub`（论坛用户 ID）、
`preferred_username`、`name`、`email`、`picture`、`groups`、`trust_level`、`minecraft_name`。

---

## 5. 第一期任务（MVP）

标 **H** 的任务只能由负责人本人做（花钱、实名、收验证码）。其余任务交给 worker。
每个任务一个分支、一个 PR，做完对照验收标准自测，并在 PR 里贴出验证过程的真实输出。

### H1 采购与账号（负责人）

- 买域名，DNS 托管到任意服务商，建好三个子域名的 A 记录指向 VPS。
- 买境外 VPS（香港或日本优先，1 核 1G、Debian 12 即可）。
- 注册事务邮件服务（Resend 或 Brevo），按它的指引给域名加 SPF/DKIM 记录，拿到 SMTP 凭据。
- 把凭据放进自有机器的 `app.yml`（不进仓库）。

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

### P1 论坛插件骨架 + 服务器状态

- 建 `plugins/discourse-gtmc/`：`plugin.rb`、站点设置、中英文 locale、路由、rspec 配置。
- 实现 4.1 里标「一」的两个接口和 `gtmc:server` API Key 作用域。
- 在 `app.yml` 的 `after_code` 钩子里把本插件装进容器（克隆本仓库后复制 `plugins/discourse-gtmc`），重建验证。
- **验收**：rspec 覆盖：心跳后状态在线、超时后离线、无 Key 或作用域不对被拒、`gtmc_enabled` 关闭时 `status.json` 404。
  （关闭插件时 Discourse 会连带停用 `gtmc:server` 作用域，只勾了它的 Key 访问服务器接口得到 403 而非 404，这是预期行为。）

### M1 MC 插件骨架 + 心跳

- 建 `mc-plugin/`：Gradle（Kotlin DSL）、Java 21、`paper-api` 1.21.x、`plugin.yml`。
  HTTP 用 JDK 自带的 `java.net.http`，JSON 用 Paper 自带的 Gson，不加其他运行时依赖。
- `config.yml`：`forum_url`（默认 `http://127.0.0.1:8880`，同机直连不绕 VPS）、`api_key`、`heartbeat_interval_seconds`（默认 30）。
  直连回环时要带 `Host: FORUM_HOST` 头，Discourse 才认；还要带 `X-Forwarded-Proto: https`，
  否则 `force_https` 会把回环上的 HTTP 请求 301 到 HTTPS（待 I3 在真机确认）。
- 定时异步上报心跳；失败只记一行警告，不刷屏、不影响服务器。
- **验收**：真服上装好后，论坛 `/gtmc/status.json` 的人数随玩家进出变化；论坛停掉时服务器 TPS 不受影响。

### T1 主题基础

- 建 `theme/`：`about.json`、深浅两套配色、`common/`、`desktop/`、`mobile/` 样式。
- 视觉方向：深色优先；草方块绿做强调色；标题和 Logo 用开源像素字体（Fusion Pixel 或 Ark Pixel，OFL 协议，
  子集化后随主题分发），**正文用系统字体**保证可读；圆角收小、边框硬朗，呼应方块感，但不要整站像素化。
- 借鉴 Linux.do 的布局：左侧边栏导航、紧凑的话题列表、醒目的分类色标。
- 颜色只通过 Discourse 的配色方案和 CSS 变量取用，样式里不写死色值。
- 开发方式：`discourse_theme watch theme/` 对着测试站实时同步。
- **验收**：桌面和手机宽度下，首页、话题页、发帖框、用户页、管理后台都没有错位或看不清的文字；
  深浅两套配色的正文对比度达到 WCAG AA。

### T2 首页服务器状态组件

- Glimmer 组件（`.gjs`），用 `api.renderInOutlet` 挂在话题列表上方。
- 读 `/gtmc/status.json`，显示在线状态、人数、版本、服务器地址（点一下复制）、地图入口。每 30 秒刷新，页面不可见时暂停。
- 三种状态都要有设计：在线、离线、接口请求失败。
- **验收**：停掉 MC 服，120 秒内组件变为离线（离线判定超时 90 秒 + 组件刷新间隔 30 秒）；断网时显示「状态暂不可用」而不是空白或报错。

### C1 内容与社区机制

- 版块已由 `site_settings.rb` 创建。为每个版块写发帖模板（如白名单申请、建筑展示、活动报名），追加进该脚本。
- 调整信任等级门槛以适配 200 人的小社区（默认值是为大站设计的），设置写进脚本并在注释里说明每一项为什么这么调。
- 写置顶帖：欢迎与社区规则、新人指南（怎么升级、各等级能做什么）。
- 侧边栏分区、徽章（如「初来乍到」「建筑师」「红石工程师」）在后台配置，步骤记进 `infra/README.md`。
- **验收**：新注册账号能看懂自己该去哪发帖、怎么升到 1 级。

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
