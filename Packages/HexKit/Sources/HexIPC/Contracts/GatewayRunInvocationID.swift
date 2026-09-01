import Foundation

/// A fixed-width server-issued identity for one admitted run invocation.
///
/// A run identifier may be reused after bounded gateway eviction, but this identity never carries
/// over to the replacement invocation. Its single UUID-string wire form keeps it bounded.
public struct GatewayRunInvocationID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: UUID

  public init(rawValue: UUID) {
    self.rawValue = rawValue
  }

  init() {
    self.init(rawValue: UUID())
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard let rawValue = UUID(uuidString: value) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Expected a UUID string for GatewayRunInvocationID."
      )
    }
    self.init(rawValue: rawValue)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue.uuidString)
  }
}
