import HexCore

/// Redacted completion state from `account/login/completed`.
public struct CodexLoginCompletion: Equatable, Sendable {
  public let loginID: CodexLoginID?
  public let succeeded: Bool

  public init(appServerParameters: JSONValue) throws {
    guard case .object(let object) = appServerParameters,
      object.keys.allSatisfy(
        Set(["error", "loginId", "onboardingEntrypoint", "success"]).contains
      ),
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
    case .some(.string(let error))
    where !error.isEmpty && error.utf8.count <= 4_096
      && !error.unicodeScalars.contains(where: Self.isUnsafePresentationScalar):
      hasError = true
    default:
      throw CodexAccountClientError.malformedResponse
    }
    guard !succeeded || !hasError else {
      throw CodexAccountClientError.malformedResponse
    }

    switch object["onboardingEntrypoint"] {
    case .none, .some(.null), .some(.string("life_sciences")):
      break
    default:
      throw CodexAccountClientError.malformedResponse
    }

    self.loginID = loginID
    self.succeeded = succeeded
  }

  private static func isUnsafePresentationScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .control, .format, .lineSeparator, .paragraphSeparator:
      true
    default:
      false
    }
  }
}
