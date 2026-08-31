import Foundation

public struct AgentEventID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
  public let rawValue: UUID

  public init(rawValue: UUID) {
    self.rawValue = rawValue
  }

  public init() {
    self.init(rawValue: UUID())
  }

  public var description: String {
    rawValue.uuidString
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard let rawValue = UUID(uuidString: value) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Expected a UUID string for AgentEventID."
      )
    }
    self.init(rawValue: rawValue)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue.uuidString)
  }
}
