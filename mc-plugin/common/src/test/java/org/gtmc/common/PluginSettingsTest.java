package org.gtmc.common;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.net.URI;
import org.junit.jupiter.api.Test;

class PluginSettingsTest {

  private static PluginSettings validate(
      String forumUrl, String forumHost, String apiKey, int heartbeatIntervalSeconds)
      throws InvalidSettingsException {
    return PluginSettings.validate(
        forumUrl, forumHost, apiKey, "survival", heartbeatIntervalSeconds);
  }

  private static PluginSettings validateWithApiKey(String apiKey) throws InvalidSettingsException {
    return validate("http://127.0.0.1:8880", "forum.example.test", apiKey, 30);
  }

  private static InvalidSettingsException rejectedServerId(String serverId) {
    return assertThrows(
        InvalidSettingsException.class,
        () ->
            PluginSettings.validate(
                "http://127.0.0.1:8880", "forum.example.test", "real-key", serverId, 30));
  }

  @Test
  void acceptsAFullyFilledInConfig() throws Exception {
    PluginSettings settings =
        validate("http://127.0.0.1:8880", "forum.example.test", "real-key", 30);

    assertEquals(URI.create("http://127.0.0.1:8880"), settings.forumUrl());
    assertEquals("forum.example.test", settings.forumHost());
    assertEquals("real-key", settings.apiKey());
    assertEquals("survival", settings.serverId());
    assertEquals(30, settings.heartbeatIntervalSeconds());
  }

  @Test
  void rejectsTheShippedPlaceholderApiKey() {
    var error = assertThrows(InvalidSettingsException.class, () -> validateWithApiKey("CHANGEME"));

    assertTrue(error.getMessage().contains("api_key"), error.getMessage());
  }

  @Test
  void rejectsTheShippedPlaceholderForumHost() {
    var error =
        assertThrows(
            InvalidSettingsException.class,
            () -> validate("http://127.0.0.1:8880", "CHANGEME", "real-key", 30));

    assertTrue(error.getMessage().contains("forum_host"), error.getMessage());
  }

  @Test
  void rejectsAMissingApiKey() {
    var error = assertThrows(InvalidSettingsException.class, () -> validateWithApiKey(""));

    assertTrue(error.getMessage().contains("api_key"), error.getMessage());
  }

  @Test
  void rejectsAForumUrlWithoutAScheme() {
    var error =
        assertThrows(
            InvalidSettingsException.class,
            () -> validate("127.0.0.1:8880", "forum.example.test", "real-key", 30));

    assertTrue(error.getMessage().contains("forum_url"), error.getMessage());
  }

  @Test
  void rejectsAnIntervalBelowTheMinimum() {
    var error =
        assertThrows(
            InvalidSettingsException.class,
            () -> validate("http://127.0.0.1:8880", "forum.example.test", "real-key", 9));

    assertTrue(error.getMessage().contains("heartbeat_interval_seconds"), error.getMessage());
  }

  @Test
  void rejectsAnIntervalAboveTheMaximum() {
    var error =
        assertThrows(
            InvalidSettingsException.class,
            () -> validate("http://127.0.0.1:8880", "forum.example.test", "real-key", 61));

    assertTrue(error.getMessage().contains("heartbeat_interval_seconds"), error.getMessage());
  }

  @Test
  void rejectsTheShippedPlaceholderServerId() {
    assertTrue(rejectedServerId("CHANGEME").getMessage().contains("server_id is not set"));
  }

  @Test
  void rejectsAMissingServerId() {
    assertTrue(rejectedServerId("").getMessage().contains("server_id"));
  }

  @Test
  void rejectsServerIdsThatBreakTheFormat() {
    for (String serverId : new String[] {"Survival", "sur vival", "sur_vival", "生存服", "a/b"}) {
      var error = rejectedServerId(serverId);
      assertTrue(error.getMessage().contains("server_id"), error.getMessage());
      assertTrue(error.getMessage().contains("'" + serverId + "'"), error.getMessage());
    }
  }

  @Test
  void acceptsServerIdsAtTheLengthBoundaries() throws Exception {
    String longestServerId = "a".repeat(32);

    assertEquals(
        longestServerId,
        PluginSettings.validate(
                "http://127.0.0.1:8880", "forum.example.test", "real-key", longestServerId, 30)
            .serverId());
    assertEquals(
        "1",
        PluginSettings.validate("http://127.0.0.1:8880", "forum.example.test", "real-key", "1", 30)
            .serverId());
  }

  @Test
  void rejectsAServerIdOneCharacterTooLong() {
    assertTrue(rejectedServerId("a".repeat(33)).getMessage().contains("server_id"));
  }
}
