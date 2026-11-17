package org.gtmc.paper;

import java.net.URI;
import java.net.URISyntaxException;
import org.bukkit.configuration.file.FileConfiguration;

/**
 * config.yml 的校验结果。配置在启动时一次读完，业务代码只拿这个 record，不再碰 FileConfiguration。
 *
 * @param forumUrl 论坛地址，已确认是带主机名的 http/https 地址
 * @param forumHost 直连回环时放进 Host 头的论坛域名
 * @param apiKey 论坛 API Key；绝不写进日志
 * @param heartbeatIntervalSeconds 心跳间隔，在 [MIN_HEARTBEAT_INTERVAL_SECONDS,
 *     MAX_HEARTBEAT_INTERVAL_SECONDS] 内
 */
record PluginSettings(URI forumUrl, String forumHost, String apiKey, int heartbeatIntervalSeconds) {

  /** 论坛占位符，出现在配置里说明部署的人还没填。 */
  private static final String PLACEHOLDER = "CHANGEME";

  /** 下限要大于单次请求的最长耗时（见 HeartbeatClient 的两个超时之和），否则上一次还没结束下一次就开始了。 */
  static final int MIN_HEARTBEAT_INTERVAL_SECONDS = 10;

  /** 上限要明显小于论坛的 gtmc_heartbeat_timeout_seconds（默认 90），丢一次心跳不能让状态闪成离线。 */
  static final int MAX_HEARTBEAT_INTERVAL_SECONDS = 60;

  static PluginSettings load(FileConfiguration config) throws InvalidSettingsException {
    URI forumUrl = parseForumUrl(config.getString("forum_url", ""));
    String forumHost = requireFilledIn(config.getString("forum_host", ""), "forum_host");
    String apiKey = requireFilledIn(config.getString("api_key", ""), "api_key");
    int intervalSeconds = config.getInt("heartbeat_interval_seconds", 30);
    if (intervalSeconds < MIN_HEARTBEAT_INTERVAL_SECONDS
        || intervalSeconds > MAX_HEARTBEAT_INTERVAL_SECONDS) {
      throw new InvalidSettingsException(
          "heartbeat_interval_seconds must be between "
              + MIN_HEARTBEAT_INTERVAL_SECONDS
              + " and "
              + MAX_HEARTBEAT_INTERVAL_SECONDS
              + " but is "
              + intervalSeconds
              + ". Fix it in plugins/GtmcPaper/config.yml and restart the server.");
    }
    return new PluginSettings(forumUrl, forumHost, apiKey, intervalSeconds);
  }

  private static URI parseForumUrl(String rawForumUrl) throws InvalidSettingsException {
    URI forumUrl;
    try {
      forumUrl = new URI(rawForumUrl.strip());
    } catch (URISyntaxException e) {
      throw invalidForumUrl(rawForumUrl);
    }
    boolean httpScheme =
        "http".equals(forumUrl.getScheme()) || "https".equals(forumUrl.getScheme());
    if (!httpScheme || forumUrl.getHost() == null) {
      throw invalidForumUrl(rawForumUrl);
    }
    return forumUrl;
  }

  private static InvalidSettingsException invalidForumUrl(String rawForumUrl) {
    return new InvalidSettingsException(
        "forum_url must be an http:// or https:// address such as http://127.0.0.1:8880 but is '"
            + rawForumUrl
            + "'. Fix it in plugins/GtmcPaper/config.yml and restart the server.");
  }

  private static String requireFilledIn(String value, String key) throws InvalidSettingsException {
    String stripped = value.strip();
    if (stripped.isEmpty() || PLACEHOLDER.equals(stripped)) {
      throw new InvalidSettingsException(
          key + " is not set. Fill it in plugins/GtmcPaper/config.yml and restart the server.");
    }
    return stripped;
  }
}
