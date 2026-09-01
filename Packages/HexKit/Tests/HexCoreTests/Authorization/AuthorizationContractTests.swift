import Foundation
import HexCore
import Testing

@Suite("Authorization contracts")
struct AuthorizationContractTests {
  @Test
  func preservesStructuredRequest() throws {
    let request = AuthorizationRequest(
      id: AuthorizationRequestID(),
      runID: AgentRunID(),
      toolCallID: ToolCallID(rawValue: "call-auth"),
      capability: CapabilityID(rawValue: "filesystem.write"),
      operation: "write",
      resource: "/tmp/example.txt",
      details: ["byteCount": .integer(12)],
      explanation: "Update the requested file."
    )

    #expect(try roundTrip(request) == request)
  }

  @Test
  func roundTripsAllowAndDenialCases() throws {
    let decisions: [AuthorizationDecision] = [
      .allow,
      .deny(reason: nil),
      .deny(reason: "Outside the granted directory."),
    ]

    for decision in decisions {
      #expect(try roundTrip(decision) == decision)
    }
  }

  private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(Value.self, from: data)
  }
}
