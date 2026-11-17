package org.gtmc.paper;

/** config.yml 里某一项缺失或不合法。消息会原样写进日志，所以必须点明是哪个配置项、该怎么改。 */
final class InvalidSettingsException extends Exception {

  InvalidSettingsException(String message) {
    super(message);
  }
}
