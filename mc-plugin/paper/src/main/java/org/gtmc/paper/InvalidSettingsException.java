package org.gtmc.paper;

/**
 * 配置里某一项缺失或不合法。消息会原样写进日志，所以必须点明是哪个配置项、该怎么改。
 *
 * <p>线程约定：无状态，任何线程都可以抛出和读取。
 */
public final class InvalidSettingsException extends Exception {

  public InvalidSettingsException(String message) {
    super(message);
  }
}
