import Foundation

/// An untagged, canonical JSON value. Integral numbers representable as `Int64` use `integer`;
/// `number` is reserved for finite fractional values and finite values outside the `Int64` range.
/// Encoding rejects a `number` that should canonically be an `integer`, preserving its case across a
/// successful encode/decode round trip.
public enum JSONValue: Codable, Equatable, Sendable {
  case null
  case boolean(Bool)
  case integer(Int64)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()

    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .boolean(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode(Double.self) {
      guard value.isFinite else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "JSON numbers must be finite."
        )
      }
      self = .number(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Expected an ordinary JSON value."
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()

    switch self {
    case .null:
      try container.encodeNil()
    case .boolean(let value):
      try container.encode(value)
    case .integer(let value):
      try container.encode(value)
    case .number(let value):
      guard value.isFinite else {
        throw EncodingError.invalidValue(
          value,
          EncodingError.Context(
            codingPath: encoder.codingPath,
            debugDescription: "JSON numbers must be finite."
          )
        )
      }
      guard Int64(exactly: value) == nil else {
        throw EncodingError.invalidValue(
          value,
          EncodingError.Context(
            codingPath: encoder.codingPath,
            debugDescription:
              "Integral JSON numbers representable as Int64 must use JSONValue.integer."
          )
        )
      }
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }
}
