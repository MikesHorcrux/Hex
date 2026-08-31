import HexCore

/// Redacted completion state from `account/login/completed`.
public struct CodexLoginCompletion: Equatable, Sendable {
  public let loginID: CodexLoginID?
  public let succeeded: Bool

  public init(appServerParameters: JSONValue) throws {
    guard case .object(let object) = appServerParameters,
      case .boolean(let succeeded)? = object["success"]
    else {
      throw CodexAccountClientError.malformedResponse
    }

    let loginID: CodexLoginID?
    switch object["loginId"] {
    case .none, .some(.null):
      loginID = nil
    case .some(.string(let rawValue)):
      loginID = try CodexLoginID(rawValue: rawValue)
    default:
      throw CodexAccountClientError.malformedResponse
    }

    let hasError: Bool
    switch object["error"] {
    case .none, .some(.null):
      hasError = false
    case .some(.string(let error)) where !error.isEmpty && error.utf8.count <= 4_096:
      hasError = true
    default:
      throw CodexAccountClientError.malformedResponse
    }
    guard !succeeded || !hasError else {
      throw CodexAccountClientError.malformedResponse
    }

    self.loginID = loginID
    self.succeeded = succeeded
  }
}
