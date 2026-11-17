package org.gtmc.paper;

import java.util.List;
import org.bukkit.entity.Player;
import org.bukkit.plugin.java.JavaPlugin;

/** GTMC Paper 插件入口。M1 只负责定时把服务器状态上报给论坛。 */
public final class GtmcPlugin extends JavaPlugin {

  private static final long TICKS_PER_SECOND = 20;

  /** Paper 的 TPS 统计偶尔会略高于 20，展示给玩家看没有意义，统一截到满值。 */
  private static final double FULL_TPS = 20.0;

  private HeartbeatClient heartbeatClient;

  @Override
  public void onLoad() {
    HeartbeatClient.allowHostHeaderOverride();
  }

  @Override
  public void onEnable() {
    saveDefaultConfig();
    PluginSettings settings;
    try {
      settings = PluginConfigReader.read(getConfig());
      heartbeatClient = new HeartbeatClient(settings, getLogger());
    } catch (InvalidSettingsException | IllegalStateException e) {
      // 配置有问题时宁可整个插件不启动，也不要在日志里反复报错。
      getLogger()
          .severe(e.getMessage() + " GtmcPaper is disabled. Config: plugins/GtmcPaper/config.yml");
      getServer().getPluginManager().disablePlugin(this);
      return;
    }

    long intervalTicks = settings.heartbeatIntervalSeconds() * TICKS_PER_SECOND;
    getServer().getScheduler().runTaskTimer(this, this::reportHeartbeat, 0L, intervalTicks);
    getLogger()
        .info(
            "Reporting heartbeat to "
                + settings.forumUrl()
                + " every "
                + settings.heartbeatIntervalSeconds()
                + "s.");
  }

  @Override
  public void onDisable() {
    getServer().getScheduler().cancelTasks(this);
    if (heartbeatClient != null) {
      heartbeatClient.close();
    }
  }

  /** 线程约定：由调度器在主线程调用。主线程只读取内存里的服务器状态，网络请求交给异步线程。 */
  private void reportHeartbeat() {
    HeartbeatPayload payload = captureHeartbeatPayload();
    getServer().getScheduler().runTaskAsynchronously(this, () -> heartbeatClient.send(payload));
  }

  /** 线程约定：必须在主线程调用，因为在线玩家列表只有主线程能安全读取。只读内存里的数据，不做任何 IO。 */
  private HeartbeatPayload captureHeartbeatPayload() {
    List<String> playerNames =
        getServer().getOnlinePlayers().stream().map(Player::getName).toList();
    double oneMinuteTps = Math.min(getServer().getTPS()[0], FULL_TPS);
    return new HeartbeatPayload(
        getServer().getMinecraftVersion(),
        playerNames.size(),
        getServer().getMaxPlayers(),
        playerNames,
        oneMinuteTps);
  }
}
