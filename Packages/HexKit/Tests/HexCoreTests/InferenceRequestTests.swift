import Foundation
import HexCore
import Testing

@Suite("Inference requests")
struct InferenceRequestTests {
  @Test
  func preservesProviderNeutralRequestFields() throws {
    let requestID = InferenceRequestID()
    let tool = ToolDefinition(
      name: "search",
      description: "Search indexed content",
      inputSchema: [
        "type": .string("object"),
        "properties": .object([
          "query": .object(["type": .string("string")])
        ]),
      ]
    )
    let request = InferenceRequest(
      id: requestID,
      providerID: ProviderID(rawValue: "provider"),
      modelID: ModelID(rawValue: "model"),
      messages: [Message(role: .developer, content: [.text("Be precise.")])],
      tools: [tool],
      toolChoice: .named("search"),
      options: InferenceOptions(maxOutputTokens: 1_024, temperature: 0.25)
    )

    let decoded = try roundTrip(request)

    #expect(decoded == request)
    #expect(decoded.id == requestID)
    #expect(decoded.messages.first?.role == .developer)
  }

  @Test
  func defaultsToAutomaticToolsAndUnspecifiedOptions() {
    let request = InferenceRequest(
      providerID: ProviderID(rawValue: "provider"),
      modelID: ModelID(rawValue: "model"),
      messages: []
    )

    #expect(request.tools.isEmpty)
    #expect(request.toolChoice == .automatic)
    #expect(request.options.maxOutputTokens == nil)
    #expect(request.options.temperature == nil)
  }

  private func roundTrip(_ value: InferenceRequest) throws -> InferenceRequest {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(InferenceRequest.self, from: data)
  }
}
