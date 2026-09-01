import HexCore
import Testing

@testable import HexProviders

@Suite("MLX tool input schema validation")
struct MLXToolInputSchemaValidatorTests {
  @Test
  func rejectsSchemasOutsideTheSupportedSubset() {
    #expect(
      MLXToolInputSchemaValidator.isSupported([
        "type": .string("object"),
        "properties": .object([
          "path": .object(["type": .string("string")])
        ]),
      ])
    )
    #expect(
      !MLXToolInputSchemaValidator.isSupported([
        "type": .string("object"),
        "properties": .object([
          "path": .object([
            "type": .string("string"),
            "pattern": .string(".+"),
          ])
        ]),
      ])
    )
    #expect(
      !MLXToolInputSchemaValidator.isSupported([
        "type": .string("string")
      ])
    )
    #expect(
      !MLXToolInputSchemaValidator.isSupported([
        "type": .string("object"),
        "minProperties": .integer(2),
        "maxProperties": .integer(1),
      ])
    )
    #expect(
      !MLXToolInputSchemaValidator.isSupported([
        "type": .string("object"),
        "required": .array([.string("path"), .string("path")]),
      ])
    )
  }

  @Test
  func validatesNestedValuesAndClosedObjects() {
    let schema: [String: JSONValue] = [
      "type": .string("object"),
      "properties": .object([
        "mode": .object([
          "type": .string("string"),
          "enum": .array([.string("read"), .string("write")]),
        ]),
        "paths": .object([
          "type": .string("array"),
          "items": .object([
            "type": .string("string"),
            "minLength": .integer(1),
          ]),
          "minItems": .integer(1),
          "maxItems": .integer(2),
        ]),
        "confirmed": .object([
          "type": .string("boolean"),
          "const": .boolean(true),
        ]),
        "note": .object([
          "type": .array([.string("string"), .string("null")])
        ]),
      ]),
      "required": .array([
        .string("mode"),
        .string("paths"),
        .string("confirmed"),
      ]),
      "additionalProperties": .boolean(false),
      "minProperties": .integer(3),
      "maxProperties": .integer(4),
    ]
    #expect(MLXToolInputSchemaValidator.isSupported(schema))

    let validArguments: [String: JSONValue] = [
      "mode": .string("read"),
      "paths": .array([.string("README.md")]),
      "confirmed": .boolean(true),
      "note": .null,
    ]
    #expect(MLXToolInputSchemaValidator.arguments(validArguments, conformTo: schema))

    let invalidArguments: [[String: JSONValue]] = [
      ["mode": .string("read"), "paths": .array([.string("README.md")])],
      [
        "mode": .string("delete"),
        "paths": .array([.string("README.md")]),
        "confirmed": .boolean(true),
      ],
      [
        "mode": .string("read"),
        "paths": .array([]),
        "confirmed": .boolean(true),
      ],
      [
        "mode": .string("read"),
        "paths": .array([.string("")]),
        "confirmed": .boolean(true),
      ],
      [
        "mode": .string("read"),
        "paths": .array([.string("a"), .string("b"), .string("c")]),
        "confirmed": .boolean(true),
      ],
      [
        "mode": .string("read"),
        "paths": .array([.string("README.md")]),
        "confirmed": .boolean(false),
      ],
      [
        "mode": .string("read"),
        "paths": .array([.string("README.md")]),
        "confirmed": .boolean(true),
        "unexpected": .null,
      ],
    ]
    for arguments in invalidArguments {
      #expect(!MLXToolInputSchemaValidator.arguments(arguments, conformTo: schema))
    }
  }
}
