package org.gtmc.common;

import com.google.gson.FieldNamingPolicy;
import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import java.util.List;

/**
 * 心跳请求体，字段与 PLAN.md 4.1 的 POST /gtmc/server/heartbeat.json 一一对应。各平台在能安全读取服务端状态的线程
 * （通常是主线程）上构造它；构造之后不可变，可以交给异步线程发送。
 *
 * @param serverId 这个服在论坛 gtmc_servers 里登记的标识；论坛靠它区分是哪个服
 * @param version Minecraft 版本号，如 1.21.11
 * @param playersOnline 当前在线人数
 * @param playersMax 人数上限
 * @param playerNames 在线玩家的游戏名（mc_name）
 * @param tps 最近一分钟的平均 TPS
 */
public record HeartbeatPayload(
    String serverId,
    String version,
    int playersOnline,
    int playersMax,
    List<String> playerNames,
    double tps) {

  /** 跨进程的 JSON 字段一律 snake_case（AGENTS.md 第 4 节）。 */
  private static final Gson GSON =
      new GsonBuilder()
          .setFieldNamingPolicy(FieldNamingPolicy.LOWER_CASE_WITH_UNDERSCORES)
          .create();

  public String toJson() {
    return GSON.toJson(this);
  }
}
