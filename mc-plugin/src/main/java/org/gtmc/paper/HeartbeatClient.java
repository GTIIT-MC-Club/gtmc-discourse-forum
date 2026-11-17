package org.gtmc.paper;

import com.google.gson.JsonObject;
import com.google.gson.JsonParseException;
import com.google.gson.JsonParser;
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.concurrent.atomic.AtomicReference;
import java.util.logging.Logger;

/**
 * 把心跳 POST 给论坛的 /gtmc/server/heartbeat.json。
 *
 * <p>论坛不可达或拒绝时不抛错、不重试：下一个间隔会带着更新的数据再发一次。失败只记一行警告， 同一个原因持续失败不重复记；原因变了才再记一行；恢复后记一行提示。
 *
 * <p>线程约定：{@link #send} 会阻塞到响应或超时，只能在异步线程调用。失败状态只被异步线程访问， 用 AtomicReference 保证不同异步线程之间的可见性。
 */
final class HeartbeatClient {

  /** 连接超时与请求超时之和（8 秒）必须小于最小心跳间隔（10 秒），这样上一次心跳一定在下一次开始前结束， 不会堆积请求。 */
  static final Duration CONNECT_TIMEOUT = Duration.ofSeconds(3);

  static final Duration REQUEST_TIMEOUT = Duration.ofSeconds(5);

  private static final String HEARTBEAT_PATH = "/gtmc/server/heartbeat.json";

  /** PLAN.md 4.1：服务器接口用 Api-Username: system。 */
  private static final String API_USERNAME = "system";

  private static final int HTTP_OK = 200;

  private final HttpClient httpClient;
  private final HttpRequest.Builder requestTemplate;
  private final Logger logger;
  private final int heartbeatIntervalSeconds;

  /** 最近一次失败的原因；为 null 表示最近一次心跳成功（或还没发过）。 */
  private final AtomicReference<String> lastFailureReason = new AtomicReference<>();

  /**
   * 允许 java.net.http 手动设置 Host 头。JDK 默认把 Host 列为受限头，直连回环时又必须带上， Discourse 才认得这是哪个站点。
   *
   * <p>这个系统属性只在 java.net.http 第一次被使用时读取，所以必须在 onLoad 里尽早调用。 如果服务器上别的插件抢先用过
   * java.net.http，这里设置就不生效，构造 {@link HeartbeatClient} 时会失败并提示改用 JVM 启动参数
   * -Djdk.httpclient.allowRestrictedHeaders=host。
   */
  static void allowHostHeaderOverride() {
    System.setProperty("jdk.httpclient.allowRestrictedHeaders", "host");
  }

  /**
   * @throws IllegalStateException Host 头被 JDK 拒绝，说明 {@link #allowHostHeaderOverride} 来得太晚
   */
  HeartbeatClient(PluginSettings settings, Logger logger) {
    this.logger = logger;
    this.heartbeatIntervalSeconds = settings.heartbeatIntervalSeconds();
    // 强制 HTTP/1.1：默认会在 http:// 上发 h2c 升级请求，对 Discourse 的 nginx 没有好处。
    this.httpClient =
        HttpClient.newBuilder()
            .version(HttpClient.Version.HTTP_1_1)
            .connectTimeout(CONNECT_TIMEOUT)
            .build();
    try {
      this.requestTemplate =
          HttpRequest.newBuilder(heartbeatUri(settings.forumUrl()))
              .version(HttpClient.Version.HTTP_1_1)
              .timeout(REQUEST_TIMEOUT)
              .header("Host", settings.forumHost())
              .header("Api-Key", settings.apiKey())
              .header("Api-Username", API_USERNAME)
              .header("Content-Type", "application/json")
              // force_https 打开时，Discourse 会把它认为的明文请求重定向到 https。
              // 直连回环走的是明文，这里声明 TLS 已在上游终结，和 Caddy 转发过来的请求保持一致。
              .header("X-Forwarded-Proto", "https");
    } catch (IllegalArgumentException e) {
      httpClient.shutdownNow();
      throw new IllegalStateException(
          "The JDK refused the Host header ("
              + e.getMessage()
              + "). Add -Djdk.httpclient.allowRestrictedHeaders=host to the server's java start"
              + " command and restart.",
          e);
    }
  }

  /** 阻塞发送一次心跳，结果只体现在日志里。只能在异步线程调用。 */
  void send(HeartbeatPayload payload) {
    HttpRequest request =
        requestTemplate.copy().POST(HttpRequest.BodyPublishers.ofString(payload.toJson())).build();
    try {
      HttpResponse<String> response =
          httpClient.send(request, HttpResponse.BodyHandlers.ofString());
      String problem = describeProblem(response);
      if (problem == null) {
        recordSuccess();
      } else {
        recordFailure(problem);
      }
    } catch (IOException e) {
      String detail = e.getMessage() == null ? "" : ": " + e.getMessage();
      recordFailure("request failed (" + e.getClass().getSimpleName() + detail + ")");
    } catch (InterruptedException e) {
      // 服务器正在关闭，请求被打断，不算论坛的错。
      Thread.currentThread().interrupt();
    }
  }

  /** 立刻放弃还在进行的请求。服务器关闭时调用。 */
  void close() {
    httpClient.shutdownNow();
  }

  private static URI heartbeatUri(URI forumUrl) {
    String base = forumUrl.toString();
    String baseWithoutTrailingSlashes = base.replaceAll("/+$", "");
    return URI.create(baseWithoutTrailingSlashes + HEARTBEAT_PATH);
  }

  /** 返回失败原因，成功返回 null。论坛的业务结论是 HTTP 200 加 status 枚举（PLAN.md 4.1）。 */
  private static String describeProblem(HttpResponse<String> response) {
    if (response.statusCode() != HTTP_OK) {
      return "forum answered HTTP " + response.statusCode() + hintFor(response.statusCode());
    }
    try {
      JsonObject body = JsonParser.parseString(response.body()).getAsJsonObject();
      boolean accepted = body.has("status") && "ok".equals(body.get("status").getAsString());
      return accepted ? null : "forum answered HTTP 200 but status was not ok";
    } catch (JsonParseException | IllegalStateException | UnsupportedOperationException e) {
      return "forum answered HTTP 200 but the body was not the expected JSON";
    }
  }

  private static String hintFor(int statusCode) {
    return switch (statusCode) {
      case 301, 302, 307, 308 ->
          " (redirect: check forum_url and forum_host in config.yml, and the forum's force_https)";
      case 403 -> " (check api_key is valid and has the gtmc:server scope)";
      case 404 -> " (check the discourse-gtmc plugin is installed and gtmc_enabled is on)";
      default -> "";
    };
  }

  private void recordSuccess() {
    if (lastFailureReason.getAndSet(null) != null) {
      logger.info("Heartbeat to the forum works again.");
    }
  }

  private void recordFailure(String reason) {
    String previousReason = lastFailureReason.getAndSet(reason);
    if (reason.equals(previousReason)) {
      return;
    }
    logger.warning(
        "Heartbeat to the forum failed: "
            + reason
            + ". Retrying every "
            + heartbeatIntervalSeconds
            + "s; this is logged again only if the reason changes. The server is not affected.");
  }
}
