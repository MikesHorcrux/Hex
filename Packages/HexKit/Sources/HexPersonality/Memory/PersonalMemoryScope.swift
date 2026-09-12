import Foundation

public struct PersonalMemoryScope: Codable, Hashable, Sendable {
  public let rawValue: String

  /// The default scope shared by the resident gateway and its Settings surface.
  public static let hex = Self(uncheckedRawValue: "hex")

  public init(rawValue: String) throws {
    guard
      let first = rawValue.utf8.first,
      rawValue.utf8.count <= 128,
      Self.isLowercaseLetterOrDigit(first),
      rawValue.utf8.dropFirst().allSatisfy({ byte in
        Self.isLowercaseLetterOrDigit(byte)
          || byte == 45
          || byte == 46
          || byte == 95
      })
    else {
      throw PersonalMemoryScopeError.invalidValue
    }
    self.rawValue = rawValue
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(rawValue: container.decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  private init(uncheckedRawValue: String) {
    rawValue = uncheckedRawValue
  }

  private static func isLowercaseLetterOrDigit(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (97...122).contains(byte)
  }
}
