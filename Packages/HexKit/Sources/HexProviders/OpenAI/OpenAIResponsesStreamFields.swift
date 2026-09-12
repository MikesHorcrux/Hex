import HexCore

struct OpenAIResponsesStreamFields: Sendable {
  func requiredValue(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> JSONValue {
    guard let value = object[key] else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    return value
  }

  func requiredString(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> String {
    guard case .string(let value)? = object[key] else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    return value
  }

  func optionalString(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> String? {
    guard let value = object[key], value != .null else { return nil }
    guard case .string(let string) = value else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    return string
  }

  func requiredObject(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> [String: JSONValue] {
    guard case .object(let value)? = object[key] else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    return value
  }

  func requiredArray(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> [JSONValue] {
    guard case .array(let value)? = object[key] else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    return value
  }

  func optionalArray(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> [JSONValue]? {
    guard let value = object[key], value != .null else { return nil }
    guard case .array(let array) = value else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    return array
  }

  func requiredIndex(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> Int {
    guard
      case .integer(let value)? = object[key],
      value >= 0,
      let index = Int(exactly: value)
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    return index
  }

  func requiredUnsigned(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> UInt64 {
    guard case .integer(let value)? = object[key], value >= 0 else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    return UInt64(value)
  }

  func optionalUnsigned(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> UInt64? {
    guard let value = object[key], value != .null else { return nil }
    guard case .integer(let integer) = value, integer >= 0 else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    return UInt64(integer)
  }
}
