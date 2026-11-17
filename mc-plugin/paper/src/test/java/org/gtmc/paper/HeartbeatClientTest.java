package org.gtmc.paper;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.google.gson.JsonParser;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.logging.Handler;
import java.util.logging.Level;
import java.util.logging.LogRecord;
import java.util.logging.Logger;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/** 用本地假论坛（JDK 自带的 HttpServer）验证心跳请求的内容和失败时的日志行为。 */
class HeartbeatClientTest {

  private static final String API_KEY = "secret-key-that-must-not-be-logged";
  private static final String FORUM_HOST = "forum.example.test";
  private static final HeartbeatPayload PAYLOAD =
      new HeartbeatPayload("1.21.11", 1, 20, List.of("Steve"), 20.0);

  /** 假论坛收到的一次请求。 */
  private record ReceivedRequest(
      String method,
      String path,
      String hostHeader,
      String apiKey,
      String apiUsername,
      String forwardedProto,
      String body) {}

  private final List<ReceivedRequest> receivedRequests = new CopyOnWriteArrayList<>();
  private final List<LogRecord> loggedRecords = new CopyOnWriteArrayList<>();
  private volatile int forumStatusCode = 200;
  private volatile String forumResponseBody = "{\"status\":\"ok\"}";
  private HttpServer forum;
  private HeartbeatClient client;

  @BeforeAll
  static void allowHostHeader() {
    HeartbeatClient.allowHostHeaderOverride();
  }

  @BeforeEach
  void startFakeForum() throws IOException {
    forum = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
    forum.createContext(
        "/",
        exchange -> {
          byte[] requestBody = exchange.getRequestBody().readAllBytes();
          receivedRequests.add(
              new ReceivedRequest(
                  exchange.getRequestMethod(),
                  exchange.getRequestURI().getPath(),
                  exchange.getRequestHeaders().getFirst("Host"),
                  exchange.getRequestHeaders().getFirst("Api-Key"),
                  exchange.getRequestHeaders().getFirst("Api-Username"),
                  exchange.getRequestHeaders().getFirst("X-Forwarded-Proto"),
                  new String(requestBody, StandardCharsets.UTF_8)));
          byte[] responseBody = forumResponseBody.getBytes(StandardCharsets.UTF_8);
          exchange.sendResponseHeaders(forumStatusCode, responseBody.length);
          exchange.getResponseBody().write(responseBody);
          exchange.close();
        });
    forum.start();
    client = newClient("http://127.0.0.1:" + forum.getAddress().getPort());
  }

  @AfterEach
  void stopFakeForum() {
    client.close();
    forum.stop(0);
  }

  private HeartbeatClient newClient(String forumUrl) {
    Logger logger = Logger.getAnonymousLogger();
    logger.setUseParentHandlers(false);
    logger.addHandler(
        new Handler() {
          @Override
          public void publish(LogRecord record) {
            loggedRecords.add(record);
          }

          @Override
          public void flush() {}

          @Override
          public void close() {}
        });
    return new HeartbeatClient(
        new PluginSettings(URI.create(forumUrl), FORUM_HOST, API_KEY, 30), logger);
  }

  private List<String> loggedMessages(Level level) {
    List<String> messages = new ArrayList<>();
    for (LogRecord record : loggedRecords) {
      if (record.getLevel().equals(level)) {
        messages.add(record.getMessage());
      }
    }
    return messages;
  }

  @Test
  void postsTheHeartbeatWithAuthenticationAndHostHeaders() {
    client.send(PAYLOAD);

    assertEquals(1, receivedRequests.size());
    ReceivedRequest request = receivedRequests.get(0);
    assertEquals("POST", request.method());
    assertEquals("/gtmc/server/heartbeat.json", request.path());
    assertEquals(FORUM_HOST, request.hostHeader());
    assertEquals(API_KEY, request.apiKey());
    assertEquals("system", request.apiUsername());
    assertEquals("https", request.forwardedProto());
    assertEquals(JsonParser.parseString(PAYLOAD.toJson()), JsonParser.parseString(request.body()));
  }

  @Test
  void doesNotDoubleTheSlashWhenForumUrlEndsWithOne() {
    client.close();
    client = newClient("http://127.0.0.1:" + forum.getAddress().getPort() + "/");

    client.send(PAYLOAD);

    assertEquals("/gtmc/server/heartbeat.json", receivedRequests.get(0).path());
  }

  @Test
  void logsNothingWhileHeartbeatsKeepSucceeding() {
    client.send(PAYLOAD);
    client.send(PAYLOAD);

    assertTrue(loggedRecords.isEmpty());
  }

  @Test
  void logsOnlyOneWarningWhenTheSameFailureRepeats() {
    forumStatusCode = 403;

    client.send(PAYLOAD);
    client.send(PAYLOAD);
    client.send(PAYLOAD);

    List<String> warnings = loggedMessages(Level.WARNING);
    assertEquals(1, warnings.size());
    assertTrue(warnings.get(0).contains("HTTP 403"), warnings.get(0));
    assertTrue(warnings.get(0).contains("gtmc:server"), warnings.get(0));
  }

  @Test
  void neverPutsTheApiKeyInTheLog() {
    forumStatusCode = 403;

    client.send(PAYLOAD);

    for (LogRecord record : loggedRecords) {
      assertFalse(record.getMessage().contains(API_KEY));
    }
  }

  @Test
  void logsAgainWhenTheFailureReasonChanges() {
    forumStatusCode = 403;
    client.send(PAYLOAD);
    forumStatusCode = 404;
    client.send(PAYLOAD);

    assertEquals(2, loggedMessages(Level.WARNING).size());
  }

  @Test
  void logsOneRecoveryLineWhenTheForumComesBack() {
    forumStatusCode = 404;
    client.send(PAYLOAD);
    forumStatusCode = 200;
    client.send(PAYLOAD);
    client.send(PAYLOAD);

    assertEquals(1, loggedMessages(Level.WARNING).size());
    assertEquals(1, loggedMessages(Level.INFO).size());
  }

  @Test
  void treatsHttp200WithoutStatusOkAsAFailure() {
    forumResponseBody = "{\"status\":\"error\"}";

    client.send(PAYLOAD);

    assertEquals(1, loggedMessages(Level.WARNING).size());
  }

  @Test
  void treatsAnHttp200ThatIsNotJsonAsAFailure() {
    forumResponseBody = "<html>maintenance</html>";

    client.send(PAYLOAD);

    assertEquals(1, loggedMessages(Level.WARNING).size());
  }

  @Test
  void treatsARedirectAsAFailureInsteadOfFollowingIt() {
    forumStatusCode = 301;

    client.send(PAYLOAD);

    List<String> warnings = loggedMessages(Level.WARNING);
    assertEquals(1, warnings.size());
    assertTrue(warnings.get(0).contains("HTTP 301"), warnings.get(0));
    assertEquals(1, receivedRequests.size());
  }

  @Test
  void doesNotWarnAboutARequestThatWasCutShortByClosing() {
    client.close();

    client.send(PAYLOAD);

    assertTrue(loggedRecords.isEmpty());
  }

  @Test
  void logsOneWarningWhenTheForumIsUnreachableAndDoesNotThrow() {
    forum.stop(0);

    client.send(PAYLOAD);
    client.send(PAYLOAD);

    assertEquals(1, loggedMessages(Level.WARNING).size());
  }
}
