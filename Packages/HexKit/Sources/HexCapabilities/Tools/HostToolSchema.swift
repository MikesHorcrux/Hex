import HexCore

public enum HostToolSchema {
  public static func object(
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

  public static func string(_ description: String, maximumLength: Int) -> JSONValue {
    .object([
      "type": .string("string"),
      "description": .string(description),
      "maxLength": .integer(Int64(maximumLength)),
    ])
  }

  public static func stringEnum(_ description: String, values: [String]) -> JSONValue {
    .object([
      "type": .string("string"),
      "description": .string(description),
      "enum": .array(values.map(JSONValue.string)),
    ])
  }

  public static func integer(
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

  static func stringArray(
    _ description: String,
    maximumItems: Int,
    maximumItemLength: Int
  ) -> JSONValue {
    .object([
      "type": .string("array"),
      "description": .string(description),
      "maxItems": .integer(Int64(maximumItems)),
      "items": .object([
        "type": .string("string"),
        "maxLength": .integer(Int64(maximumItemLength)),
      ]),
    ])
  }
}
