import Dispatch
import Foundation
import HexCapabilities
import HexCore
import HexPersonality

struct PersonalMemoryToolArguments: Sendable {
  private let values: [String: JSONValue]

  init(
    _ call: ToolCall,
    toolName: PersonalMemoryToolName,
    allowedNames: Set<String>
  ) throws {
    guard call.name == toolName.rawValue else {
      throw PersonalMemoryToolError.invalidArguments
    }
    guard
      call.arguments.count <= 16,
      Set(call.arguments.keys).isSubset(of: allowedNames),
      let encoded = try? JSONEncoder().encode(call.arguments),
      encoded.count <= 256 * 1_024
    else {
      throw PersonalMemoryToolError.invalidArguments
    }
    values = call.arguments
  }

  func requiredString(
    named name: String,
    maximumBytes: Int,
    allowsEmpty: Bool = false
  ) throws -> String {
    guard case .string(let value) = values[name] else {
      throw PersonalMemoryToolError.invalidArguments
    }
    guard
      allowsEmpty || !value.isEmpty,
      value.utf8.count <= maximumBytes,
      !value.contains("\0"),
      allowsEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw PersonalMemoryToolError.invalidArguments
    }
    return value
  }

  func requiredScope(boundTo boundScope: PersonalMemoryScope) throws -> PersonalMemoryScope {
    let rawValue = try requiredString(named: "scope", maximumBytes: 128)
    guard let scope = try? PersonalMemoryScope(rawValue: rawValue) else {
      throw PersonalMemoryToolError.invalidArguments
    }
    guard scope == boundScope else {
      throw PersonalMemoryToolError.scopeMismatch
    }
    return scope
  }

  func requiredID() throws -> PersonalMemoryID {
    let rawValue = try requiredString(named: "id", maximumBytes: 256)
    guard
      rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
      !rawValue.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw PersonalMemoryToolError.invalidArguments
    }
    return PersonalMemoryID(rawValue: rawValue)
  }

  func requiredKind() throws -> PersonalMemoryKind {
    let rawValue = try requiredString(named: "kind", maximumBytes: 64)
    guard let kind = PersonalMemoryKind(rawValue: rawValue) else {
      throw PersonalMemoryToolError.invalidArguments
    }
    return kind
  }

  func optionalKind() throws -> PersonalMemoryKind? {
    guard values["kind"] != nil else {
      return nil
    }
    let rawValue = try requiredString(named: "kind", maximumBytes: 64)
    guard let kind = PersonalMemoryKind(rawValue: rawValue) else {
      throw PersonalMemoryToolError.invalidArguments
    }
    return kind
  }

  func requiredSource() throws -> PersonalMemorySource {
    let rawValue = try requiredString(named: "source", maximumBytes: 64)
    guard let source = PersonalMemorySource(rawValue: rawValue) else {
      throw PersonalMemoryToolError.invalidArguments
    }
    return source
  }

  func requiredQuery() throws -> String {
    let query = try requiredString(named: "query", maximumBytes: 4_096)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !query.isEmpty,
      !query.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      query.split(whereSeparator: \Character.isWhitespace).count <= 32
    else {
      throw PersonalMemoryToolError.invalidArguments
    }
    return query
  }

  func limit() throws -> Int {
    guard let rawValue = values["limit"] else {
      return PersonalMemoryToolResponse.maximumResults
    }
    guard case .integer(let value) = rawValue,
      let limit = Int(exactly: value),
      (1...PersonalMemoryToolResponse.maximumResults).contains(limit)
    else {
      throw PersonalMemoryToolError.invalidArguments
    }
    return limit
  }

  func optionalPinned() throws -> Bool {
    guard let rawValue = values["is_pinned"] else {
      return false
    }
    guard case .boolean(let value) = rawValue else {
      throw PersonalMemoryToolError.invalidArguments
    }
    return value
  }
}
