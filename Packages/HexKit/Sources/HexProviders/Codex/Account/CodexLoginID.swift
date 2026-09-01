/// Correlation identifier issued by Codex for one managed login flow.
public struct CodexLoginID: Equatable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) throws {
    guard !rawValue.isEmpty, rawValue.utf8.count <= 512 else {
      throw CodexAccountClientError.malformedResponse
    }
    guard rawValue.unicodeScalars.allSatisfy(Self.isAllowedScalar) else {
      throw CodexAccountClientError.malformedResponse
    }
    self.rawValue = rawValue
  }

  private static func isAllowedScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 45...46, 48...58, 65...90, 95, 97...122:
      true
    default:
      false
    }
  }
}
