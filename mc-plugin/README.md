# mc-plugin（MC 服务器端接入）

跑在各个 MC 服务器上，定时把服务器状态（版本、在线人数、玩家名、TPS）上报给论坛插件
`discourse-gtmc` 的 `POST /gtmc/server/heartbeat.json`。论坛首页的状态组件读的就是这份数据。
接口约定见仓库根目录 `PLAN.md` 4.1，本目录不引用其他部分的源码。

社团有 4 个互相独立的服，每个服装一份插件，靠配置里的 `server_id` 区分。目前只有心跳（里程碑 M1 / R2）。

## 子项目

Gradle 多项目，根目录统一管理版本号和 Spotless 格式规则。

| 子项目 | 职责 | 约束 |
|---|---|---|
| `common/` | 与平台无关的逻辑：心跳组包、HTTP 发送、失败限频、配置校验 | 只依赖 JDK 和 Gson；编译目标 Java 17；不许引用任何 Bukkit/Paper/加载器的类 |
| `paper/` | Paper/Purpur 插件 `gtmc-paper`：读取服务器状态、调度、读 `config.yml` | Java 21；薄适配层，规则都放 `common/` |

模组端（Fabric/Forge/NeoForge）等负责人确认各服的核心和版本后再建，同样复用 `common/`（任务 F1）。
新增平台时只写读状态、调度和读配置，把原始配置值交给 `PluginSettings.validate`，把状态交给 `HeartbeatClient`。

`common/` 的 Javadoc 写明了每个类的线程约定：`HeartbeatClient.send` 会阻塞，只能在异步线程调用；
`HeartbeatPayload` 在能安全读取服务端状态的线程（通常是主线程）上构造，之后不可变。

## 构建与测试

需要 JDK 21。构建用仓库自带的 Gradle wrapper，不用另装 Gradle：

```sh
cd mc-plugin
./gradlew build           # 编译 + 单元测试 + spotlessCheck
./gradlew spotlessApply   # 自动格式化（google-java-format）
```

产物是 `paper/build/libs/gtmc-paper-0.1.0.jar`。`common/` 的类已经打包在这个 jar 里，不需要单独部署。

测试里的「假论坛」是 JDK 自带的 `HttpServer`，`common/` 的测试不需要 Paper、Discourse，也不依赖任何 Bukkit 类。
`paper/` 的测试只确认 `config.yml` 的每个键都被读进了正确的设置项，校验规则在 `common/` 里测。

`common/` 用 `options.release = 17` 编译，误用 Java 17 之后的 API 会直接编译失败；
但测试是跑在构建用的 JDK 21 上的，没有在真正的 Java 17 运行时里跑过。

## 部署（Paper）

1. 在论坛后台（管理 → API）生成一个 API Key：用户级别选「单个用户」，用户名填 `system`，
   作用域只勾 `gtmc:server`。这个作用域由论坛插件注册（任务 P1）。4 个服共用同一个 Key 即可。
2. 在论坛后台的 `gtmc_servers` 设置里登记这个服的 `server_id`、展示名、玩家连接地址和地图入口（任务 R1）。
3. 把 `gtmc-paper-0.1.0.jar` 放进 MC 服务器的 `plugins/` 目录，启动一次服务器生成 `plugins/GtmcPaper/config.yml`。
4. 编辑 `config.yml`，填 `forum_host`、`api_key` 和 `server_id`（占位符 `CHANGEME` 没改插件会拒绝启动并说明是哪一项），重启服务器。
5. 看日志里有没有 `Reporting heartbeat to ... every 30s as server_id '...'.`，再访问 `https://<论坛域名>/gtmc/status.json`
   确认这个服的 `online` 为 `true`。

### 配置项

| 项 | 默认 | 说明 |
|---|---|---|
| `forum_url` | `http://127.0.0.1:8880` | 论坛地址。同机直连本机回环，不绕 VPS |
| `forum_host` | `CHANGEME` | 论坛域名，作为 `Host` 头发出，必须和 `app.yml` 的 `DISCOURSE_HOSTNAME` 一致 |
| `api_key` | `CHANGEME` | 论坛 API Key，是密钥，不要提交到仓库 |
| `server_id` | `CHANGEME` | 这个服的标识，必填，格式 `^[a-z0-9-]{1,32}$`，如 `survival`。必须和论坛 `gtmc_servers` 里登记的一致，4 个服各填各的 |
| `heartbeat_interval_seconds` | `30` | 心跳间隔，取值 10 到 60 |

`server_id` 格式不对或没填，插件会禁用自己并在日志里写明原因。论坛回 `unknown_server`（`server_id`
没在 `gtmc_servers` 里登记）时，插件记一行警告，提示去后台登记；同一个原因不重复记，登记之后恢复会记一行提示。

### 关于 Host 头和 JVM 参数

直连回环时必须带 `Host` 头，但 JDK 的 `java.net.http` 默认禁止手动设置它。插件在 `onLoad` 里设置了
`jdk.httpclient.allowRestrictedHeaders=host`，这个属性只在 `java.net.http` **第一次被使用时**读取。
如果服务器上别的插件抢先用过它，插件启动时会报错：

```
The JDK refused the Host header (...). Add -Djdk.httpclient.allowRestrictedHeaders=host to the server's java start command and restart.
```

照提示把该参数加到启动命令里（`java` 和 `-jar` 之间）即可，例如：

```sh
java -Xmx4G -Djdk.httpclient.allowRestrictedHeaders=host -jar paper.jar nogui
```

### 请求里的 `X-Forwarded-Proto: https`

`infra/discourse/site_settings.rb` 打开了 `force_https`。直连回环走的是明文 HTTP，如果不声明 TLS 已在上游终结，
Discourse 会回 301 跳转到 https，心跳就永远到不了。所以插件固定带上 `X-Forwarded-Proto: https`，
和经过 Caddy 的请求保持一致。（这一点在真实 Discourse 上还没有验证过，见 PR 说明。）

## 行为约定

- **主线程不做 IO。** 主线程只读取内存里的服务器状态（在线玩家、TPS），HTTP 请求在 Paper 的异步线程里发送。
- **论坛不可达或拒绝时服务器不受影响。** 请求有超时（连接 3 秒、整体 5 秒），失败只记一行警告，
  不重试、不堆积，下一个间隔带着新数据再发。同一个原因持续失败不重复记，原因变了再记一行，恢复后记一行提示。
- 心跳不跟随重定向；论坛回 301/302 会按失败处理并在警告里给出排查提示。
- `tps` 是最近一分钟的平均值，截到 20。
- 日志里不出现 API Key。
