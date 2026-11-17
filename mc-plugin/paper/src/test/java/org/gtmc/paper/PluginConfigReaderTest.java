package org.gtmc.paper;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.net.URI;
import org.bukkit.configuration.InvalidConfigurationException;
import org.bukkit.configuration.file.YamlConfiguration;
import org.gtmc.common.InvalidSettingsException;
import org.gtmc.common.PluginSettings;
import org.junit.jupiter.api.Test;

/** 校验规则在 common 里测；这里只确认 config.yml 的每个键都被读进了正确的设置项。 */
class PluginConfigReaderTest {

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
  void readsEveryKeyOfAFullyFilledInConfig() throws Exception {
    PluginSettings settings = PluginConfigReader.read(parse(VALID_CONFIG));

    assertEquals(URI.create("http://127.0.0.1:8880"), settings.forumUrl());
    assertEquals("forum.example.test", settings.forumHost());
    assertEquals("real-key", settings.apiKey());
    assertEquals(30, settings.heartbeatIntervalSeconds());
  }

  @Test
  void reportsAMissingKeyAsNotSetInsteadOfCrashing() throws Exception {
    var config = parse(VALID_CONFIG.replace("api_key: \"real-key\"", ""));

    var error = assertThrows(InvalidSettingsException.class, () -> PluginConfigReader.read(config));

    assertTrue(error.getMessage().contains("api_key"), error.getMessage());
  }

  @Test
  void fallsBackToTheShippedDefaultIntervalWhenTheKeyIsMissing() throws Exception {
    var config = parse(VALID_CONFIG.replace("heartbeat_interval_seconds: 30", ""));

    assertEquals(30, PluginConfigReader.read(config).heartbeatIntervalSeconds());
  }
}
