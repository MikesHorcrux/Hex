import Foundation

public struct AuthorizationSessionID: RawRepresentable, Codable, Hashable, Sendable,
  CustomStringConvertible
{
  public let rawValue: UUID

  public init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }

  public var description: String {
    rawValue.uuidString.lowercased()
  }
}
