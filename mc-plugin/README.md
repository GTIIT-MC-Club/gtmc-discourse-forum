# gtmc-paper（Paper 插件）

跑在 MC 服务器上，定时把服务器状态（版本、在线人数、玩家名、TPS）上报给论坛插件
`discourse-gtmc` 的 `POST /gtmc/server/heartbeat.json`。论坛首页的状态组件读的就是这份数据。
接口约定见仓库根目录 `PLAN.md` 4.1，本目录不引用其他部分的源码。

当前只有心跳（里程碑 M1）。运行时只用 JDK 和 Paper 自带的库：HTTP 用 `java.net.http`，JSON 用 Paper 自带的 Gson。

## 构建与测试

需要 JDK 21。构建用仓库自带的 Gradle wrapper，不用另装 Gradle：

```sh
cd mc-plugin
./gradlew build      # 编译 + 单元测试 + spotlessCheck，产物在 build/libs/gtmc-paper-0.1.0.jar
./gradlew spotlessApply   # 自动格式化（google-java-format）
```

测试里的「假论坛」是 JDK 自带的 `HttpServer`，不需要启动 Paper 或 Discourse。

## 部署

1. 在论坛后台（管理 → API）生成一个 API Key：用户级别选「单个用户」，用户名填 `system`，
   作用域只勾 `gtmc:server`。这个作用域由论坛插件注册（任务 P1）。
2. 把 `gtmc-paper-0.1.0.jar` 放进 MC 服务器的 `plugins/` 目录，启动一次服务器生成 `plugins/GtmcPaper/config.yml`。
3. 编辑 `config.yml`，填 `forum_host` 和 `api_key`（占位符 `CHANGEME` 没改插件会拒绝启动并说明是哪一项），重启服务器。
4. 看日志里有没有 `Reporting heartbeat to ... every 30s.`，再访问 `https://<论坛域名>/gtmc/status.json` 确认 `online` 为 `true`。

### 配置项

| 项 | 默认 | 说明 |
|---|---|---|
| `forum_url` | `http://127.0.0.1:8880` | 论坛地址。同机直连本机回环，不绕 VPS |
| `forum_host` | `CHANGEME` | 论坛域名，作为 `Host` 头发出，必须和 `app.yml` 的 `DISCOURSE_HOSTNAME` 一致 |
| `api_key` | `CHANGEME` | 论坛 API Key，是密钥，不要提交到仓库 |
| `heartbeat_interval_seconds` | `30` | 心跳间隔，取值 10 到 60 |

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
