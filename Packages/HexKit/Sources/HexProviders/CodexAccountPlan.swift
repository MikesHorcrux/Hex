import Foundation

/// A forward-compatible, non-secret ChatGPT plan identifier reported by Codex app-server.
public struct CodexAccountPlan: Equatable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) throws {
    guard !rawValue.isEmpty, rawValue.utf8.count <= 64 else {
      throw CodexAccountClientError.malformedResponse
    }
    guard rawValue.unicodeScalars.allSatisfy(Self.isAllowedScalar) else {
      throw CodexAccountClientError.malformedResponse
    }
    self.rawValue = rawValue
  }

  private static func isAllowedScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 48...57, 97...122:
      true
    case 95:
      true
    default:
      false
    }
  }
}
