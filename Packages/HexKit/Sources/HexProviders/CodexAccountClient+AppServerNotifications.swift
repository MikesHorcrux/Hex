extension CodexAccountClient: CodexAppServerNotificationHandler {
  public func handle(_ notification: CodexAppServerNotification) async throws {
    guard notification.method == "account/login/completed" else {
      return
    }
    guard let parameters = notification.parameters else {
      throw CodexAccountClientError.malformedResponse
    }
    try acceptLoginCompletion(
      CodexLoginCompletion(appServerParameters: parameters)
    )
  }
}
