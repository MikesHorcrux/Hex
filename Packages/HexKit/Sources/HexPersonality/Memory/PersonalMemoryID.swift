import Foundation

public struct PersonalMemoryID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String = UUID().uuidString.lowercased()) {
    self.rawValue = rawValue
  }
}
