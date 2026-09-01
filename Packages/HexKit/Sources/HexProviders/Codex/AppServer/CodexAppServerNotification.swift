import HexCore

/// One validated app-server notification with its wire header removed.
public struct CodexAppServerNotification: Equatable, Sendable {
  public let method: String
  public let parameters: JSONValue?
}
