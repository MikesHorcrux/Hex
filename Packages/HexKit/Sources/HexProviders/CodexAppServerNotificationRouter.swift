/// Immutable exact-method routing for app-server notifications.
///
/// Unknown notifications are ignored for forward compatibility. A routed handler failure remains
/// fail-closed at the owning connection.
public struct CodexAppServerNotificationRouter: CodexAppServerNotificationHandler, Sendable {
  private let handlers: [String: any CodexAppServerNotificationHandler]

  public init(routes: [CodexAppServerNotificationRoute]) throws {
    guard routes.count <= 64 else {
      throw CodexAppServerConnectionError.invalidConfiguration
    }
    var handlers: [String: any CodexAppServerNotificationHandler] = [:]
    handlers.reserveCapacity(routes.count)
    for route in routes {
      guard handlers[route.method] == nil else {
        throw CodexAppServerConnectionError.invalidConfiguration
      }
      handlers[route.method] = route.handler
    }
    self.handlers = handlers
  }

  public func handle(_ notification: CodexAppServerNotification) async throws {
    guard let handler = handlers[notification.method] else { return }
    try Task.checkCancellation()
    try await handler.handle(notification)
  }
}
