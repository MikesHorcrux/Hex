import HexCore
import Testing

@testable import HexProviders

@Suite("Codex app-server notification routing")
struct CodexAppServerNotificationRouterTests {
  @Test
  func routesOnlyTheExactRegisteredMethod() async throws {
    let loginHandler = RecordingCodexAppServerNotificationHandler()
    let accountHandler = RecordingCodexAppServerNotificationHandler()
    let router = try CodexAppServerNotificationRouter(
      routes: [
        try CodexAppServerNotificationRoute(
          method: "account/login/completed",
          handler: loginHandler
        ),
        try CodexAppServerNotificationRoute(
          method: "account/updated",
          handler: accountHandler
        ),
      ]
    )
    let login = CodexAppServerNotification(
      method: "account/login/completed",
      parameters: .object([:])
    )

    try await router.handle(login)
    try await router.handle(
      CodexAppServerNotification(method: "thread/started", parameters: .object([:]))
    )

    #expect(await loginHandler.notifications() == [login])
    #expect(await accountHandler.notifications().isEmpty)
  }

  @Test
  func rejectsDuplicateInvalidAndUnboundedRoutes() throws {
    let handler = RecordingCodexAppServerNotificationHandler()
    #expect(throws: CodexAppServerConnectionError.invalidConfiguration) {
      try CodexAppServerNotificationRoute(method: "account\nspoof", handler: handler)
    }
    let duplicate = try CodexAppServerNotificationRoute(
      method: "account/updated",
      handler: handler
    )
    #expect(throws: CodexAppServerConnectionError.invalidConfiguration) {
      try CodexAppServerNotificationRouter(routes: [duplicate, duplicate])
    }
    let routes = try (0...64).map { index in
      try CodexAppServerNotificationRoute(method: "event/\(index)", handler: handler)
    }
    #expect(throws: CodexAppServerConnectionError.invalidConfiguration) {
      try CodexAppServerNotificationRouter(routes: routes)
    }
  }
}
