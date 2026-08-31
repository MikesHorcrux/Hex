import HexCore

enum WorkspaceToolSchema {
  static func object(
    properties: [String: JSONValue],
    required: [String]
  ) -> [String: JSONValue] {
    [
      "type": .string("object"),
      "additionalProperties": .boolean(false),
      "properties": .object(properties),
      "required": .array(required.map(JSONValue.string)),
    ]
  }

  static func string(_ description: String, maximumLength: Int) -> JSONValue {
    .object([
      "type": .string("string"),
      "description": .string(description),
      "maxLength": .integer(Int64(maximumLength)),
    ])
  }

  static func integer(
    _ description: String,
    minimum: Int,
    maximum: Int
  ) -> JSONValue {
    .object([
      "type": .string("integer"),
      "description": .string(description),
      "minimum": .integer(Int64(minimum)),
      "maximum": .integer(Int64(maximum)),
    ])
  }
}
