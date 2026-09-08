import HexCore

/// Validates object-rooted tool schemas with primitive/union types, nested properties and items,
/// required/additional-property rules, enum/const constraints, and bounded collection lengths.
/// Request admission rejects every schema keyword outside this explicit subset.
enum MLXToolInputSchemaValidator {
  private enum SchemaType: String, Hashable {
    case array
    case boolean
    case integer
    case null
    case number
    case object
    case string
  }

  private static let supportedKeywords: Set<String> = [
    "additionalProperties",
    "const",
    "default",
    "description",
    "enum",
    "items",
    "maxItems",
    "maxLength",
    "maxProperties",
    "minItems",
    "minLength",
    "minProperties",
    "properties",
    "required",
    "title",
    "type",
  ]

  static func isSupported(_ schema: [String: JSONValue]) -> Bool {
    guard isSupportedSchema(.object(schema), isRoot: true) else {
      return false
    }
    guard let types = schemaTypes(schema["type"]) else {
      return false
    }
    return types.isEmpty || types.contains(.object)
  }

  static func arguments(
    _ arguments: [String: JSONValue],
    conformTo schema: [String: JSONValue]
  ) -> Bool {
    // Request admission validates the immutable definition once before generation begins.
    matches(.object(arguments), schema: .object(schema))
  }

  private static func isSupportedSchema(
    _ schemaValue: JSONValue,
    isRoot: Bool = false
  ) -> Bool {
    if case .boolean = schemaValue {
      return !isRoot
    }
    guard case .object(let schema) = schemaValue else {
      return false
    }
    guard
      schema.keys.allSatisfy(supportedKeywords.contains),
      let types = schemaTypes(schema["type"]),
      validateStringAnnotation(schema["title"]),
      validateStringAnnotation(schema["description"]),
      validateEnum(schema["enum"]),
      validateNonnegativeInteger(schema["minLength"]),
      validateNonnegativeInteger(schema["maxLength"]),
      validateNonnegativeInteger(schema["minItems"]),
      validateNonnegativeInteger(schema["maxItems"]),
      validateNonnegativeInteger(schema["minProperties"]),
      validateNonnegativeInteger(schema["maxProperties"]),
      validateRange(schema, minimumKey: "minLength", maximumKey: "maxLength"),
      validateRange(schema, minimumKey: "minItems", maximumKey: "maxItems"),
      validateRange(schema, minimumKey: "minProperties", maximumKey: "maxProperties")
    else {
      return false
    }

    if hasAnyKey(
      schema,
      keys: ["properties", "required", "additionalProperties", "minProperties", "maxProperties"]
    ), !types.isEmpty, !types.contains(.object) {
      return false
    }
    if hasAnyKey(schema, keys: ["items", "minItems", "maxItems"]),
      !types.isEmpty, !types.contains(.array)
    {
      return false
    }
    if hasAnyKey(schema, keys: ["minLength", "maxLength"]),
      !types.isEmpty, !types.contains(.string)
    {
      return false
    }

    if let properties = schema["properties"] {
      guard case .object(let propertySchemas) = properties else {
        return false
      }
      for propertySchema in propertySchemas.values {
        guard isSupportedSchema(propertySchema) else {
          return false
        }
      }
    }

    if let required = schema["required"] {
      guard case .array(let names) = required else {
        return false
      }
      var seenNames = Set<String>()
      for name in names {
        guard case .string(let value) = name, seenNames.insert(value).inserted else {
          return false
        }
      }
    }

    if let additionalProperties = schema["additionalProperties"] {
      guard isSupportedSchema(additionalProperties) else {
        return false
      }
    }
    if let items = schema["items"] {
      guard isSupportedSchema(items) else {
        return false
      }
    }
    return true
  }

  private static func matches(
    _ value: JSONValue,
    schema schemaValue: JSONValue
  ) -> Bool {
    if case .boolean(let acceptsValue) = schemaValue {
      return acceptsValue
    }
    guard
      case .object(let schema) = schemaValue,
      let types = schemaTypes(schema["type"])
    else {
      return false
    }
    if !types.isEmpty, !types.contains(where: { matchesType(value, type: $0) }) {
      return false
    }
    if case .array(let allowedValues) = schema["enum"], !allowedValues.contains(value) {
      return false
    }
    if let constant = schema["const"], constant != value {
      return false
    }

    switch value {
    case .object(let object):
      return matchesObject(object, schema: schema)
    case .array(let array):
      return matchesArray(array, schema: schema)
    case .string(let string):
      return matchesCount(
        string.unicodeScalars.count,
        schema: schema,
        minimumKey: "minLength",
        maximumKey: "maxLength"
      )
    case .null, .boolean, .integer, .number:
      return true
    }
  }

  private static func matchesObject(
    _ object: [String: JSONValue],
    schema: [String: JSONValue]
  ) -> Bool {
    guard
      matchesCount(
        object.count,
        schema: schema,
        minimumKey: "minProperties",
        maximumKey: "maxProperties"
      ),
      requiredNames(in: schema).allSatisfy({ object[$0] != nil })
    else {
      return false
    }

    let propertySchemas: [String: JSONValue]
    if case .object(let values) = schema["properties"] {
      propertySchemas = values
    } else {
      propertySchemas = [:]
    }
    for (name, value) in object {
      if let propertySchema = propertySchemas[name] {
        guard matches(value, schema: propertySchema) else {
          return false
        }
      } else if let additionalProperties = schema["additionalProperties"] {
        guard matches(value, schema: additionalProperties) else {
          return false
        }
      }
    }
    return true
  }

  private static func matchesArray(
    _ array: [JSONValue],
    schema: [String: JSONValue]
  ) -> Bool {
    guard
      matchesCount(
        array.count,
        schema: schema,
        minimumKey: "minItems",
        maximumKey: "maxItems"
      )
    else {
      return false
    }
    guard let itemSchema = schema["items"] else {
      return true
    }
    return array.allSatisfy { matches($0, schema: itemSchema) }
  }

  private static func matchesType(
    _ value: JSONValue,
    type: SchemaType
  ) -> Bool {
    switch (type, value) {
    case (.array, .array), (.boolean, .boolean), (.integer, .integer), (.null, .null),
      (.object, .object), (.string, .string), (.number, .integer), (.number, .number):
      return true
    default:
      return false
    }
  }

  private static func schemaTypes(_ value: JSONValue?) -> [SchemaType]? {
    guard let value else {
      return []
    }
    let rawTypes: [String]
    switch value {
    case .string(let rawType):
      rawTypes = [rawType]
    case .array(let values):
      guard !values.isEmpty else {
        return nil
      }
      var result: [String] = []
      result.reserveCapacity(values.count)
      for value in values {
        guard case .string(let rawType) = value else {
          return nil
        }
        result.append(rawType)
      }
      rawTypes = result
    default:
      return nil
    }

    var seenTypes = Set<SchemaType>()
    var result: [SchemaType] = []
    for rawType in rawTypes {
      guard
        let type = SchemaType(rawValue: rawType),
        seenTypes.insert(type).inserted
      else {
        return nil
      }
      result.append(type)
    }
    return result
  }

  private static func requiredNames(in schema: [String: JSONValue]) -> [String] {
    guard case .array(let values) = schema["required"] else {
      return []
    }
    return values.compactMap { value in
      guard case .string(let name) = value else {
        return nil
      }
      return name
    }
  }

  private static func matchesCount(
    _ count: Int,
    schema: [String: JSONValue],
    minimumKey: String,
    maximumKey: String
  ) -> Bool {
    if let minimum = nonnegativeInteger(schema[minimumKey]), count < minimum {
      return false
    }
    if let maximum = nonnegativeInteger(schema[maximumKey]), count > maximum {
      return false
    }
    return true
  }

  private static func validateStringAnnotation(_ value: JSONValue?) -> Bool {
    guard let value else {
      return true
    }
    if case .string = value {
      return true
    }
    return false
  }

  private static func validateEnum(_ value: JSONValue?) -> Bool {
    guard let value else {
      return true
    }
    guard case .array(let values) = value, !values.isEmpty else {
      return false
    }
    for index in values.indices where values[..<index].contains(values[index]) {
      return false
    }
    return true
  }

  private static func validateNonnegativeInteger(_ value: JSONValue?) -> Bool {
    guard let value else {
      return true
    }
    return nonnegativeInteger(value) != nil
  }

  private static func nonnegativeInteger(_ value: JSONValue?) -> Int? {
    guard
      case .integer(let integer) = value,
      integer >= 0,
      let result = Int(exactly: integer)
    else {
      return nil
    }
    return result
  }

  private static func validateRange(
    _ schema: [String: JSONValue],
    minimumKey: String,
    maximumKey: String
  ) -> Bool {
    guard
      let minimum = nonnegativeInteger(schema[minimumKey]),
      let maximum = nonnegativeInteger(schema[maximumKey])
    else {
      return true
    }
    return minimum <= maximum
  }

  private static func hasAnyKey(
    _ schema: [String: JSONValue],
    keys: [String]
  ) -> Bool {
    keys.contains { schema[$0] != nil }
  }
}
