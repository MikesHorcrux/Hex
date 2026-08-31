/// One exact app-server notification route.
public struct CodexAppServerNotificationRoute: Sendable {
  public let method: String
  let handler: any CodexAppServerNotificationHandler

  public init(
    method: String,
    handler: any CodexAppServerNotificationHandler
  ) throws {
    guard CodexAppServerConnection.validMethod(method) else {
      throw CodexAppServerConnectionError.invalidConfiguration
    }
    self.method = method
    self.handler = handler
  }
}
