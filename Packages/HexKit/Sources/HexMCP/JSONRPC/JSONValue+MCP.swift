import HexCore

extension JSONValue {
  var mcpObject: [String: JSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  var mcpArray: [JSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  var mcpString: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  var mcpBoolean: Bool? {
    guard case .boolean(let value) = self else { return nil }
    return value
  }

  var mcpInteger: Int64? {
    guard case .integer(let value) = self else { return nil }
    return value
  }
}
