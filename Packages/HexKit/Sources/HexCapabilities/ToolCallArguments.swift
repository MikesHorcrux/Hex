import Foundation
import HexCore

struct ToolCallArguments: Sendable {
  private let values: [String: JSONValue]

  init(
    _ values: [String: JSONValue],
    allowedNames: Set<String>
  ) throws {
    guard
      values.count <= 32,
      Set(values.keys).isSubset(of: allowedNames),
      let encoded = try? JSONEncoder().encode(values),
      encoded.count <= 2 * 1_024 * 1_024
    else {
      throw ToolCallArgumentsError.invalidArguments
    }
    self.values = values
  }

  func requiredString(
    named name: String,
    maximumBytes: Int,
    allowsEmpty: Bool = false
  ) throws -> String {
    guard case .string(let value) = values[name] else {
      throw ToolCallArgumentsError.invalidArguments
    }
    guard
      allowsEmpty || !value.isEmpty,
      value.utf8.count <= maximumBytes,
      !value.contains("\0")
    else {
      throw ToolCallArgumentsError.invalidArguments
    }
    return value
  }

  func optionalString(named name: String, maximumBytes: Int) throws -> String? {
    guard let rawValue = values[name] else {
      return nil
    }
    guard case .string(let value) = rawValue,
      !value.isEmpty,
      value.utf8.count <= maximumBytes,
      !value.contains("\0")
    else {
      throw ToolCallArgumentsError.invalidArguments
    }
    return value
  }

  func requiredInteger(
    named name: String,
    range: ClosedRange<Int>
  ) throws -> Int {
    guard case .integer(let rawValue) = values[name],
      let value = Int(exactly: rawValue),
      range.contains(value)
    else {
      throw ToolCallArgumentsError.invalidArguments
    }
    return value
  }
}
