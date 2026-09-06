import HexCore

nonisolated enum HexJSONValueFormatter {
  static func string(from value: JSONValue) -> String {
    switch value {
    case .null:
      return "null"
    case .boolean(let value):
      return value ? "true" : "false"
    case .integer(let value):
      return String(value)
    case .number(let value):
      return String(value)
    case .string(let value):
      return value
    case .array(let values):
      return "[" + values.map { string(from: $0) }.joined(separator: ", ") + "]"
    case .object(let values):
      let pairs = values.keys.sorted().compactMap { key -> String? in
        guard let value = values[key] else { return nil }
        return "\(key): \(string(from: value))"
      }
      return "{" + pairs.joined(separator: ", ") + "}"
    }
  }
}
