import Foundation
import HexCore
import Testing

@Suite("JSONValue")
struct JSONValueTests {
  @Test
  func decodesNestedUntaggedJSON() throws {
    let data = try #require(
      """
      {"name":"hex","enabled":true,"nothing":null,"items":[1,2.5,{"nested":"value"}]}
      """.data(using: .utf8)
    )
    let expected = JSONValue.object([
      "name": .string("hex"),
      "enabled": .boolean(true),
      "nothing": .null,
      "items": .array([
        .integer(1),
        .number(2.5),
        .object(["nested": .string("value")]),
      ]),
    ])

    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

    #expect(decoded == expected)
    #expect(try roundTrip(decoded) == expected)
  }

  @Test
  func distinguishesIntegerAndFractionalNumber() throws {
    let integerData = try #require("42".data(using: .utf8))
    let numberData = try #require("42.5".data(using: .utf8))

    #expect(try JSONDecoder().decode(JSONValue.self, from: integerData) == .integer(42))
    #expect(try JSONDecoder().decode(JSONValue.self, from: numberData) == .number(42.5))
  }

  @Test
  func rejectsNonfiniteNumbers() {
    for value in [Double.nan, Double.infinity, -Double.infinity] {
      #expect(throws: EncodingError.self) {
        try JSONEncoder().encode(JSONValue.number(value))
      }
    }
  }

  @Test
  func rejectsIntegralDoublesThatHaveCanonicalIntegerRepresentations() {
    for value in [42.0, -0.0] {
      #expect(throws: EncodingError.self) {
        try JSONEncoder().encode(JSONValue.number(value))
      }
    }
  }

  @Test
  func permitsIntegralDoublesOutsideInt64Range() throws {
    let value = 9_223_372_036_854_775_808.0
    let number = JSONValue.number(value)

    #expect(try roundTrip(number) == number)
  }

  @Test
  func sentinelStringsRemainStringsWithNonconformingFloatStrategy() throws {
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
      positiveInfinity: "Infinity",
      negativeInfinity: "-Infinity",
      nan: "NaN"
    )

    for sentinel in ["Infinity", "-Infinity", "NaN"] {
      let data = try JSONEncoder().encode(sentinel)
      #expect(try decoder.decode(JSONValue.self, from: data) == .string(sentinel))
    }
  }

  @Test
  func rejectsNonfiniteDoubleFromCustomDecoder() throws {
    do {
      _ = try JSONValue(from: NonfiniteDoubleDecoder())
      Issue.record("Expected nonfinite decoded number to be rejected.")
    } catch DecodingError.dataCorrupted(let context) {
      #expect(context.debugDescription == "JSON numbers must be finite.")
    } catch {
      Issue.record("Expected dataCorrupted, received: \(error)")
    }
  }

  private func roundTrip(_ value: JSONValue) throws -> JSONValue {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(JSONValue.self, from: data)
  }

  private struct NonfiniteDoubleDecoder: Decoder {
    var codingPath: [any CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key>(
      keyedBy type: Key.Type
    ) throws -> KeyedDecodingContainer<Key> where Key: CodingKey {
      throw StubError.unsupported
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
      throw StubError.unsupported
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
      NonfiniteDoubleContainer()
    }
  }

  private struct NonfiniteDoubleContainer: SingleValueDecodingContainer {
    var codingPath: [any CodingKey] { [] }

    func decodeNil() -> Bool { false }

    func decode(_ type: Bool.Type) throws -> Bool { try unsupported() }
    func decode(_ type: String.Type) throws -> String { try unsupported() }
    func decode(_ type: Double.Type) throws -> Double { .infinity }
    func decode(_ type: Float.Type) throws -> Float { try unsupported() }
    func decode(_ type: Int.Type) throws -> Int { try unsupported() }
    func decode(_ type: Int8.Type) throws -> Int8 { try unsupported() }
    func decode(_ type: Int16.Type) throws -> Int16 { try unsupported() }
    func decode(_ type: Int32.Type) throws -> Int32 { try unsupported() }
    func decode(_ type: Int64.Type) throws -> Int64 { try unsupported() }
    func decode(_ type: UInt.Type) throws -> UInt { try unsupported() }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try unsupported() }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try unsupported() }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try unsupported() }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try unsupported() }

    func decode<Value>(_ type: Value.Type) throws -> Value where Value: Decodable {
      try unsupported()
    }

    private func unsupported<Value>() throws -> Value {
      throw StubError.unsupported
    }
  }

  private enum StubError: Error {
    case unsupported
  }
}
