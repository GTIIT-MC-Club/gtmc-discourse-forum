package org.gtmc.paper;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.net.URI;
import org.bukkit.configuration.InvalidConfigurationException;
import org.bukkit.configuration.file.YamlConfiguration;
import org.junit.jupiter.api.Test;

class PluginSettingsTest {

  private static final String VALID_CONFIG =
      """
      forum_url: "http://127.0.0.1:8880"
      forum_host: "forum.example.test"
      api_key: "real-key"
      heartbeat_interval_seconds: 30
      """;

  private static YamlConfiguration parse(String yaml) throws InvalidConfigurationException {
    YamlConfiguration config = new YamlConfiguration();
    config.loadFromString(yaml);
    return config;
  }

  @Test
  void loadsAFullyFilledInConfig() throws Exception {
    PluginSettings settings = PluginSettings.load(parse(VALID_CONFIG));

    assertEquals(URI.create("http://127.0.0.1:8880"), settings.forumUrl());
    assertEquals("forum.example.test", settings.forumHost());
    assertEquals("real-key", settings.apiKey());
    assertEquals(30, settings.heartbeatIntervalSeconds());
  }

  @Test
  void rejectsTheShippedPlaceholderApiKey() throws Exception {
    var config = parse(VALID_CONFIG.replace("real-key", "CHANGEME"));

    var error = assertThrows(InvalidSettingsException.class, () -> PluginSettings.load(config));

    assertTrue(error.getMessage().contains("api_key"), error.getMessage());
  }

  @Test
  void rejectsTheShippedPlaceholderForumHost() throws Exception {
    var config = parse(VALID_CONFIG.replace("forum.example.test", "CHANGEME"));

    var error = assertThrows(InvalidSettingsException.class, () -> PluginSettings.load(config));

    assertTrue(error.getMessage().contains("forum_host"), error.getMessage());
  }

  @Test
  void rejectsAMissingApiKey() throws Exception {
    var config = parse(VALID_CONFIG.replace("api_key: \"real-key\"", ""));

    var error = assertThrows(InvalidSettingsException.class, () -> PluginSettings.load(config));

    assertTrue(error.getMessage().contains("api_key"), error.getMessage());
  }

  @Test
  void rejectsAForumUrlWithoutAScheme() throws Exception {
    var config = parse(VALID_CONFIG.replace("http://127.0.0.1:8880", "127.0.0.1:8880"));

    var error = assertThrows(InvalidSettingsException.class, () -> PluginSettings.load(config));

    assertTrue(error.getMessage().contains("forum_url"), error.getMessage());
  }

  @Test
  void rejectsAnIntervalBelowTheMinimum() throws Exception {
    var config = parse(VALID_CONFIG.replace("interval_seconds: 30", "interval_seconds: 9"));

    var error = assertThrows(InvalidSettingsException.class, () -> PluginSettings.load(config));

    assertTrue(error.getMessage().contains("heartbeat_interval_seconds"), error.getMessage());
  }

  @Test
  void rejectsAnIntervalAboveTheMaximum() throws Exception {
    var config = parse(VALID_CONFIG.replace("interval_seconds: 30", "interval_seconds: 61"));

    var error = assertThrows(InvalidSettingsException.class, () -> PluginSettings.load(config));

    assertTrue(error.getMessage().contains("heartbeat_interval_seconds"), error.getMessage());
  }
}
