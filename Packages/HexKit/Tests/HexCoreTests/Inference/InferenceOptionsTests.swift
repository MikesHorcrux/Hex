import Foundation
import Testing

@testable import HexCore

@Suite("Inference options")
struct InferenceOptionsTests {
  @Test
  func reasoningEffortSurvivesWireEncoding() throws {
    let options = InferenceOptions(
      maxOutputTokens: 512,
      temperature: 0.25,
      reasoningEffort: .xhigh
    )

    let encoded = try JSONEncoder().encode(options)
    let decoded = try JSONDecoder().decode(InferenceOptions.self, from: encoded)

    #expect(decoded == options)
  }

  @Test
  func legacyPayloadWithoutReasoningEffortUsesProviderDefault() throws {
    let payload = Data(#"{"maxOutputTokens":512,"temperature":0.25}"#.utf8)

    let decoded = try JSONDecoder().decode(InferenceOptions.self, from: payload)

    #expect(decoded.reasoningEffort == nil)
  }
}
