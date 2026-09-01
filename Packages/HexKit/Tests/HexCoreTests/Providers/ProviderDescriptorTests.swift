import Foundation
import HexCore
import Testing

@Suite("Provider descriptors")
struct ProviderDescriptorTests {
  @Test
  func capabilitiesHaveStableWireNames() throws {
    let expected = [
      "text_input",
      "image_input",
      "streaming",
      "tool_calling",
      "parallel_tool_calling",
      "structured_output",
      "reasoning_summary",
    ]

    #expect(InferenceCapability.allCases.map(\.rawValue) == expected)
    for capability in InferenceCapability.allCases {
      #expect(try roundTrip(capability) == capability)
    }
  }

  @Test
  func roundTripsProviderAndKnownModelMetadata() throws {
    let providerID = ProviderID(rawValue: "openai")
    let provider = ProviderDescriptor(
      id: providerID,
      displayName: "OpenAI",
      capabilities: [.textInput, .streaming, .toolCalling]
    )
    let model = ModelDescriptor(
      id: ModelID(rawValue: "example-model"),
      providerID: providerID,
      displayName: "Example Model",
      capabilities: [.textInput, .streaming],
      contextWindow: 128_000,
      maxOutputTokens: 16_384
    )

    #expect(try roundTrip(provider) == provider)
    #expect(try roundTrip(model) == model)
  }

  @Test
  func representsUnknownModelLimits() throws {
    let model = ModelDescriptor(
      id: ModelID(rawValue: "local-model"),
      providerID: ProviderID(rawValue: "mlx"),
      displayName: "Local Model",
      capabilities: [.textInput]
    )

    #expect(model.contextWindow == nil)
    #expect(model.maxOutputTokens == nil)
    #expect(try roundTrip(model) == model)
  }

  private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(Value.self, from: data)
  }
}
