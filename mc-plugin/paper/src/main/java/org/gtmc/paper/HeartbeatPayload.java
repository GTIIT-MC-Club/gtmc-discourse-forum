package org.gtmc.paper;

import com.google.gson.FieldNamingPolicy;
import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import java.util.List;
import org.bukkit.Server;
import org.bukkit.entity.Player;

/**
 * 心跳请求体，字段与 PLAN.md 4.1 的 POST /gtmc/server/heartbeat.json 一一对应。
 *
 * @param version Minecraft 版本号，如 1.21.11
 * @param playersOnline 当前在线人数
 * @param playersMax 人数上限
 * @param playerNames 在线玩家的游戏名（mc_name）
 * @param tps 最近一分钟的平均 TPS
 */
record HeartbeatPayload(
    String version, int playersOnline, int playersMax, List<String> playerNames, double tps) {

  /** Paper 的 TPS 统计偶尔会略高于 20，展示给玩家看没有意义，统一截到满值。 */
  private static final double FULL_TPS = 20.0;

  /** 跨进程的 JSON 字段一律 snake_case（AGENTS.md 第 4 节）。 */
  private static final Gson GSON =
      new GsonBuilder()
          .setFieldNamingPolicy(FieldNamingPolicy.LOWER_CASE_WITH_UNDERSCORES)
          .create();

  /**
   * 读取当前服务器状态。只读内存里的数据，不做任何 IO。
   *
   * <p>线程约定：必须在主线程调用，因为在线玩家列表只有主线程能安全读取。
   */
  static HeartbeatPayload capture(Server server) {
    List<String> playerNames = server.getOnlinePlayers().stream().map(Player::getName).toList();
    double oneMinuteTps = Math.min(server.getTPS()[0], FULL_TPS);
    return new HeartbeatPayload(
        server.getMinecraftVersion(),
        playerNames.size(),
        server.getMaxPlayers(),
        playerNames,
        oneMinuteTps);
  }

  String toJson() {
    return GSON.toJson(this);
  }
}
