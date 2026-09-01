import Foundation
import HexCore
import Testing

@Suite("Identifiers")
struct IdentifierTests {
  @Test
  func uuidBackedIdentifiersUseSingleStringEncoding() throws {
    let uuid = try #require(UUID(uuidString: "12345678-1234-5678-9ABC-DEF012345678"))

    try assertSingleStringRoundTrip(AgentRunID(rawValue: uuid), expected: uuid.uuidString)
    try assertSingleStringRoundTrip(AgentEventID(rawValue: uuid), expected: uuid.uuidString)
    try assertSingleStringRoundTrip(
      AuthorizationRequestID(rawValue: uuid), expected: uuid.uuidString)
    try assertSingleStringRoundTrip(InferenceRequestID(rawValue: uuid), expected: uuid.uuidString)
    try assertSingleStringRoundTrip(MessageID(rawValue: uuid), expected: uuid.uuidString)
  }

  @Test
  func stringBackedIdentifiersPreserveExactValues() throws {
    let exactValue = "  Provider.Model:α  "

    try assertSingleStringRoundTrip(ProviderID(rawValue: exactValue), expected: exactValue)
    try assertSingleStringRoundTrip(ModelID(rawValue: exactValue), expected: exactValue)
    try assertSingleStringRoundTrip(CapabilityID(rawValue: exactValue), expected: exactValue)
    try assertSingleStringRoundTrip(ToolCallID(rawValue: exactValue), expected: exactValue)
  }

  @Test
  func generatedIdentifiersAreNonempty() {
    #expect(!AgentRunID().description.isEmpty)
    #expect(!AgentEventID().description.isEmpty)
    #expect(!AuthorizationRequestID().description.isEmpty)
    #expect(!InferenceRequestID().description.isEmpty)
    #expect(!MessageID().description.isEmpty)
    #expect(!ToolCallID().description.isEmpty)
  }

  private func assertSingleStringRoundTrip<Value: Codable & Equatable & CustomStringConvertible>(
    _ value: Value,
    expected: String
  ) throws {
    let data = try JSONEncoder().encode(value)
    let encoded = try #require(String(data: data, encoding: .utf8))
    #expect(encoded == "\"\(expected)\"")
    #expect(try JSONDecoder().decode(Value.self, from: data) == value)
    #expect(value.description == expected)
  }
}
