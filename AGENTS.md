# 代码规范

本仓库所有代码（Ruby、Ember/JS、SCSS、Java、TypeScript、配置和脚本）都遵守本文件。
做什么见 `PLAN.md`；这里只管怎么写。

总原则：**代码是写给下一个接手的同学看的。** 社团成员每年换届，接手的人没有上下文、没人可问。
读代码的人应该不用猜。

## 1. 工作方式

- 一个任务一个分支一个 PR，只做 `PLAN.md` 里那个任务写明的事。顺手发现的问题记进 PR 描述，不要顺手改。
- 跨代码库的接口以 `PLAN.md` 第 4 节为准。要改接口，先改那一节，再改代码，同一个 PR 提交。
- 不确定 Discourse 或 Paper 的某个 API 是否存在、叫什么名字时，去查当前版本的源码或文档，不要凭印象写。
- PR 描述写：做了什么、怎么验证的（贴真实输出）、没做什么或没验证什么。没跑过的东西不许写成「已验证」。
- 密钥、Token、密码不进仓库。示例配置里用 `CHANGEME` 占位。
- **不许动本机的网络配置**：不改系统代理、VPN、DNS、hosts、路由，不改 shell 或全局的 `http_proxy` 等环境变量，
  不改 git/npm/gradle/docker 的全局代理设置，不装或启停 VPN/代理软件。网络不通就停下来如实汇报，不要自己想办法绕。

## 2. 语言

- 标识符、文件名、提交信息、日志：英文。
- 注释和文档：中文。
- 用户看得见的文字：全部走各自的 i18n 机制，中文为主，不在代码里硬编码。
  文案要说清发生了什么、接下来该做什么。例：
  - 好：`这个游戏名已被其他论坛账号绑定。如果它是你的，请到「白名单与申诉」版块发帖。`
  - 差：`绑定失败` / `Error 422`

## 3. 术语表

一个概念在所有代码库里只有一个名字。不要发明同义词。

| 概念 | 名字 | 不要用 |
|---|---|---|
| 论坛账号 | `user`（Discourse 原有） | `member`、`account` |
| 玩家的游戏名 | `mc_name` / `mcName` | `username`、`player_name`、`ign`、`minecraft_id` |
| 论坛账号与游戏名的绑定记录 | `minecraft_account` | `binding`、`link`、`profile` |
| 进服用的一次性 6 位码 | `login_code` | `token`、`otp`、`verify_code` |
| 对某个 IP 的免码信任 | `ip_trust` | `session`、`remember_me` |
| 进服后未验证的状态 | `frozen` | `locked`、`pending`、`limbo` |
| MC 服定时上报的状态 | `heartbeat` | `ping`、`report` |
| 跑在 VPS 上的服务 | `bridge` | `gateway`、`relay`、`bot` |

`username` 永远指论坛用户名，`mc_name` 永远指游戏名，两者不可混用。

## 4. 命名

- 名字说明这个东西**是什么**，用上面的领域词汇。读到名字就该知道里面装的是什么。
  - 好：`trusted_until`、`frozenPlayers`、`heartbeat_timeout_seconds`
  - 差：`data`、`info`、`tmp`、`result2`、`flag`、`manager`、`helper`、`utils`
- 不缩写，除了已成惯例的 `id`、`ip`、`url`、`mc`（仅用于 `mc_name`）、`tps`。
- 带单位的数值把单位写进名字：`ttl_seconds`、`reconnectDelayMillis`、`cooldown_days`。
- 布尔值读起来是判断句：`ip_trusted`、`isFrozen`、`renamable?`。不用否定式命名（`not_bound`、`disable_x`）。
- 函数名是动词短语，说明效果：`freeze(player)`、`issue_login_code`、`relayToDiscord`。
  会抛错或有副作用的函数，名字不能看起来像个纯查询。
- 集合用复数，映射说明键和值：`players`、`frozenSinceByPlayerId`。
- 作用域越大名字越完整；三行以内的循环变量可以短。
- 大小写跟随各语言惯例：Ruby `snake_case`，Java/TS `camelCase`，类型 `PascalCase`，常量 `SCREAMING_SNAKE_CASE`，
  SCSS 类名 `kebab-case` 并以 `gtmc-` 开头。跨进程的 JSON 字段一律 `snake_case`。

## 5. 注释

注释解释**为什么**，代码本身说明**做什么**。读者能从代码看出来的东西不要再写一遍。

该写的：

- 不明显的原因和约束：`# 离线模式的 UUID 由名字的精确大小写算出，所以大小写不符必须拒绝，不能自动纠正`
- 为什么没用更直观的写法；外部系统的坑；数值是怎么定的
- 公开的类和接口：一两句说明职责和调用方需要知道的约定

不该写的：

- 复述代码：`// 遍历玩家`、`# 返回结果`
- 分隔线和横幅：`// ========== 工具函数 ==========`
- 被注释掉的代码、修改记录（`// 2026-11 修复了 xxx`）、署名。这些信息属于 git。
- 没有去处的 `TODO`。要么现在做，要么写成 `TODO(#issue 编号)`。
- 对读者的客套或情绪（`// 这里有点 hack，凑合用`）。写清楚它 hack 在哪、什么条件下可以去掉。

注释和代码不一致时，两个都算错。改代码时同步改注释。

## 6. 结构

- 一个函数做一件事，长到要滚屏就拆。先处理异常情况并提前返回，主流程不缩进在层层 `if` 里。
- 不为还没出现的需求写代码：不加没人要的配置项，不为只有一个实现的东西抽接口，不写「以后可能用得上」的参数。
  第三次重复时再抽象。
- 校验放在边界（HTTP 入口、配置加载、命令输入），内部代码信任已经校验过的数据，不重复防御。
- 不出现魔法数字。部署时可能要调的进配置或站点设置，其余的定义成具名常量并注明依据。
- 状态尽量少，能算出来的不存。可变的共享状态要说明由哪个线程访问。
- 依赖能不加就不加。每加一个运行时依赖，在 PR 里说明为什么标准库或宿主自带的不够用。
- 删代码就删干净，不留兼容层、空壳、`_unused` 重命名。

## 7. 错误处理

- 出错要响：不吞异常，不写空的 `catch`/`rescue`，不用默认值掩盖失败。
- 只捕获自己知道怎么处理的错误，其余的让它往上抛。
- 外部调用（论坛 API、Discord、WebSocket）必然会失败，每一处都要明确写出失败时的行为，
  并且这个行为要在 `PLAN.md` 或注释里有据可查（例：论坛不可达时 MC 插件怎么办，见 4.2）。
- 日志一行说清：发生了什么、涉及谁、接下来会怎样。重复性的失败要限频，不刷屏。日志里不打印密钥和登录码。
- 涉及安全的判断默认拒绝：分不清就不放行。密钥和登录码的比较用常数时间比较。

## 8. 各语言的补充

**Ruby（Discourse 插件）**
- 格式和 lint 用 `rubocop-discourse`，不自定义规则。
- 只用 Discourse 公开的插件 API（`add_to_serializer`、`add_api_key_scope`、`register_asset` 等）。
  不 monkey-patch 核心类，不依赖核心的私有方法。
- 所有类放在 `DiscourseGtmc` 模块下。业务逻辑放在普通 Ruby 类里，控制器只做取参、调用、渲染。
- 每个接口都有 request spec，覆盖成功、每一种失败、以及权限。

**JavaScript / Ember（插件前端和主题）**
- 用 Discourse 官方的 eslint、prettier、stylelint 配置。
- 新组件一律 Glimmer（`.gjs`）。不用已弃用的 widget 和旧式 Ember 组件。
- 不用 jQuery，不直接操作 DOM，不覆盖核心模板。通过插件出口（outlet）和 `withPluginApi` 扩展。

**界面规则（设计稿 `design/mockups/` 的约定，主题和插件都要遵守）**
- 能用图标、颜色、形状表达的，不写说明文字；说明放进悬停提示（`data-tooltip`）。不用「xx · xx」这种圆点分隔的元信息，用布局、标签、图标分开。
- 只有图标的按钮必须是正方形；接近正方形的元素（图标块、日期块、头像）一律做成严格正方形。
- 自画图标一律 8×8 网格，只以 8px 的整数倍显示（16/24/32px）；像素字体只取 12px 的整数倍并关闭抗锯齿，只用于标签、人数、日期。
- 提示框、正文、标题、按钮永远用系统字体。
- 选中态用荧光笔样式，不用左边框竖条。
- 动效只用 `--gtmc-duration-state`、`--gtmc-tooltip-delay`、`--gtmc-ease` 三个令牌，并尊重 `prefers-reduced-motion`。
- 空状态写一句简短的占位文字，不放虚线空框；有没有内容，同类条目高度一致。
- 例外：全局提示服务需要在文档级监听指针和焦点事件、自己摆放提示层，这是唯一允许直接操作 DOM 的代码，集中在一个文件里并注释原因。

**SCSS（主题）**
- 颜色、间距、字号只用 Discourse 的 CSS 变量和主题变量，不写死色值。
- 不用 `!important`；选择器压不过核心样式时，提高选择器的针对性并注释原因。
- 自己的类名以 `gtmc-` 开头。尽量少依赖核心的类名层级，核心升级会改它们。

**Java（Paper 插件）**
- Java 21，`google-java-format`（通过 Spotless 在构建时检查）。
- 主线程上不做任何网络和磁盘 IO。回到主线程操作游戏对象时用调度器，并在方法注释里写明线程约定。
- 用 `record` 表达数据，用 `Optional` 而不是返回 `null`。事件监听器按职责分类，一个类不超过一个关注点。
- 文本用 Adventure 的 `Component`，不用 `§` 颜色码。

**TypeScript（bridge）**
- `strict` 全开，不用 `any` 和非空断言（`!`）；外部输入先用 schema 校验再进入类型系统。
- 格式用 prettier 默认配置，lint 用 `typescript-eslint` 推荐规则。
- 配置在启动时一次读完并校验，缺项直接退出并说明缺了哪个。业务代码里不读 `process.env`。
- `async` 函数的 Promise 必须被 `await` 或显式处理，不留悬空的 Promise。

**配置与脚本**
- 每个配置文件开头用注释写明：放在哪台机器的哪个路径、怎么生效。
- 脚本要能重复执行而不出错（参考 `infra/discourse/site_settings.rb`）。
- 示例配置里每个非默认值都注释原因。

## 9. 测试

- 测行为，不测实现。测试名是一句完整的话，描述场景和期望：
  `it "rejects a login code that was already used"`。
- 重点覆盖边界：权限、非法输入、过期、并发、外部依赖失败。
- 测试里不 `sleep`，时间用框架的时间冻结工具控制。
- 不为了让测试通过而改弱断言、跳过用例。测试失败说明代码或理解有问题，先弄清是哪个。

## 10. 提交

- Conventional Commits，英文祈使句，说明意图：`feat(plugin): issue one-time login codes`。
- 范围用目录名：`infra`、`theme`、`plugin`、`mc-plugin`、`bridge`、`docs`。
- 一个提交一件事。格式化改动和逻辑改动分开提交。
