package org.gtmc.common;

import static org.junit.jupiter.api.Assertions.assertEquals;

import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import java.util.List;
import java.util.Set;
import org.junit.jupiter.api.Test;

class HeartbeatPayloadTest {

  @Test
  void serializesExactlyTheFieldsOfTheHeartbeatContractInSnakeCase() {
    var payload = new HeartbeatPayload("1.21.11", 2, 20, List.of("Steve", "Alex_01"), 19.98);

    JsonObject json = JsonParser.parseString(payload.toJson()).getAsJsonObject();

    assertEquals(
        Set.of("version", "players_online", "players_max", "player_names", "tps"), json.keySet());
    assertEquals("1.21.11", json.get("version").getAsString());
    assertEquals(2, json.get("players_online").getAsInt());
    assertEquals(20, json.get("players_max").getAsInt());
    assertEquals(
        List.of("Steve", "Alex_01"),
        json.getAsJsonArray("player_names").asList().stream().map(e -> e.getAsString()).toList());
    assertEquals(19.98, json.get("tps").getAsDouble());
  }

  @Test
  void serializesAnEmptyServerWithAnEmptyPlayerNamesArray() {
    var payload = new HeartbeatPayload("1.21.11", 0, 20, List.of(), 20.0);

    JsonObject json = JsonParser.parseString(payload.toJson()).getAsJsonObject();

    assertEquals(0, json.getAsJsonArray("player_names").size());
  }
}
