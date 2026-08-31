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

  private func roundTrip(_ value: JSONValue) throws -> JSONValue {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(JSONValue.self, from: data)
  }
}
