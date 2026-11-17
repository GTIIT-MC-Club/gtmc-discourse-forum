package org.gtmc.paper;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.net.URI;
import org.junit.jupiter.api.Test;

class PluginSettingsTest {

  private static PluginSettings validate(
      String forumUrl, String forumHost, String apiKey, int heartbeatIntervalSeconds)
      throws InvalidSettingsException {
    return PluginSettings.validate(forumUrl, forumHost, apiKey, heartbeatIntervalSeconds);
  }

  private static PluginSettings validateWithApiKey(String apiKey) throws InvalidSettingsException {
    return validate("http://127.0.0.1:8880", "forum.example.test", apiKey, 30);
  }

  @Test
  void acceptsAFullyFilledInConfig() throws Exception {
    PluginSettings settings =
        validate("http://127.0.0.1:8880", "forum.example.test", "real-key", 30);

    assertEquals(URI.create("http://127.0.0.1:8880"), settings.forumUrl());
    assertEquals("forum.example.test", settings.forumHost());
    assertEquals("real-key", settings.apiKey());
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
}
