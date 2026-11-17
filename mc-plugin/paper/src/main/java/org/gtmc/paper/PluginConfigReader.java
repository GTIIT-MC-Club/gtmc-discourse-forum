package org.gtmc.paper;

import org.bukkit.configuration.file.FileConfiguration;
import org.gtmc.common.InvalidSettingsException;
import org.gtmc.common.PluginSettings;

/** 把 config.yml 的原始值交给 common 校验。Paper 这一侧只负责「从 YAML 里取值」，规则都在 common。 */
final class PluginConfigReader {

  /** 与 resources/config.yml 里写的默认值一致。 */
  private static final int DEFAULT_HEARTBEAT_INTERVAL_SECONDS = 30;

  private PluginConfigReader() {}

  /**
   * 缺失的字符串项按空串处理，让 common 报「未设置」而不是 NullPointerException。
   *
   * @throws InvalidSettingsException 任何一项缺失、仍是占位符或不合法
   */
  static PluginSettings read(FileConfiguration config) throws InvalidSettingsException {
    return PluginSettings.validate(
        config.getString("forum_url", ""),
        config.getString("forum_host", ""),
        config.getString("api_key", ""),
        config.getInt("heartbeat_interval_seconds", DEFAULT_HEARTBEAT_INTERVAL_SECONDS));
  }
}
