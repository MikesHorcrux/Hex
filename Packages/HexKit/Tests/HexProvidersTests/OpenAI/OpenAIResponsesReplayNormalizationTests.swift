import Foundation
import HexCore
import Testing

@testable import HexProviders

@Suite("OpenAI replay normalization")
struct OpenAIResponsesReplayNormalizationTests {
  @Test(arguments: ["commentary", "final_answer", "unknown-provider-phase"])
  func replaysOnlyAllowlistedFieldsIncludingNestedContent(phase: String) throws {
    let user = Message(role: .user, content: [.text("Check the weather")])
    let call = ToolCall(
      id: ToolCallID(rawValue: "call_weather"),
      name: "lookup_weather",
      arguments: ["city": .string("Paris")]
    )
    let output: [JSONValue] = [
      .object([
        "id": .string("rs_provider"), "type": .string("reasoning"),
        "status": .string("completed"), "encrypted_content": .string("encrypted-state"),
        "provider_extra": .string("drop"),
        "summary": .array([
          .object([
            "type": .string("summary_text"), "text": .string("Checking"),
            "id": .string("summary_provider"), "provider_extra": .string("drop"),
          ])
        ]),
      ]),
      .object([
        "id": .string("msg_provider"), "type": .string("message"),
        "role": .string("assistant"), "status": .string("completed"),
        "phase": .string(phase), "provider_extra": .string("drop"),
        "content": .array([
          .object([
            "type": .string("output_text"), "text": .string("Checking."),
            "id": .string("part_provider"), "logprobs": .array([]),
            "annotations": .array([
              .object(["type": .string("file_citation"), "file_id": .string("file_provider")])
            ]),
          ]),
          .object([
            "type": .string("refusal"), "refusal": .string("Cannot do more."),
            "id": .string("refusal_provider"),
          ]),
        ]),
      ]),
      .object([
        "id": .string("fc_provider"), "type": .string("function_call"),
        "status": .string("completed"), "call_id": .string(call.id.rawValue),
        "name": .string(call.name), "arguments": .string("{\"city\":\"Paris\"}"),
        "provider_extra": .string("drop"),
      ]),
    ]
    let state = OpenAILocalContinuationState(
      responseID: "resp_parent", modelID: OpenAIResponsesTestFixture.model().id,
      baseMessageCount: 1, knownMessageIDs: [user.id],
      knownMessageFingerprints: [try OpenAIMessageFingerprint.make(for: user)],
      replaySegments: [
        OpenAILocalReplaySegment(afterMessageCount: 1, outputItems: output, encodedByteCount: 1)
      ],
      encodedByteCount: 1
    )
    let request = OpenAIResponsesTestFixture.request(
      previousResponseID: state.responseID,
      messages: [
        user,
        Message(role: .assistant, content: [.text("Checking.Cannot do more."), .toolCall(call)]),
        Message(
          role: .tool,
          content: [.toolResult(ToolResult(toolCallID: call.id, status: .success, output: .null))]
        ),
      ]
    )
    let plan = try OpenAIResponsesRequestBuilder(
      configuration: OpenAIResponsesConfiguration(
        service: .chatGPTCodexSubscription, models: [OpenAIResponsesTestFixture.model()]
      )
    ).build(request, serverState: nil, localState: state)
    let body = try #require(JSONSerialization.jsonObject(with: plan.body) as? [String: Any])
    let input = try #require(body["input"] as? [[String: Any]])
    #expect(input.count == 5)
    #expect(Set(input[1].keys) == ["type", "encrypted_content", "summary"])
    let summary = try #require(input[1]["summary"] as? [[String: Any]])
    #expect(Set(summary[0].keys) == ["type", "text"])
    #expect(summary[0]["text"] as? String == "Checking")
    let expectedMessageKeys: Set<String> =
      phase == "unknown-provider-phase"
      ? ["type", "role", "status", "content"]
      : ["type", "role", "status", "content", "phase"]
    #expect(Set(input[2].keys) == expectedMessageKeys)
    let content = try #require(input[2]["content"] as? [[String: Any]])
    #expect(Set(content[0].keys) == ["type", "text", "annotations"])
    #expect((content[0]["annotations"] as? [Any])?.isEmpty == true)
    #expect(Set(content[1].keys) == ["type", "refusal"])
    #expect(Set(input[3].keys) == ["type", "call_id", "name", "arguments"])
    #expect(input[3]["call_id"] as? String == call.id.rawValue)
    #expect(Set(input[4].keys) == ["type", "call_id", "output"])
  }

  @Test
  func perRequestEffortOverridesTheConfiguredDefault() throws {
    let request = OpenAIResponsesTestFixture.request(
      options: InferenceOptions(reasoningEffort: .high))
    let plan = try OpenAIResponsesRequestBuilder(
      configuration: OpenAIResponsesTestFixture.configuration()
    ).build(request, serverState: nil, localState: nil)
    let body = try #require(JSONSerialization.jsonObject(with: plan.body) as? [String: Any])
    let reasoning = try #require(body["reasoning"] as? [String: Any])
    #expect(reasoning["effort"] as? String == "high")
  }

  @Test
  func advertisedEffortsValidateExplicitChoiceAndResolveAutomatic() throws {
    let base = OpenAIResponsesTestFixture.model()
    let model = ModelDescriptor(
      id: base.id, providerID: base.providerID, displayName: base.displayName,
      capabilities: base.capabilities,
      supportedReasoningEfforts: [.medium, .high], defaultReasoningEffort: .medium
    )
    let builder = OpenAIResponsesRequestBuilder(
      configuration: try OpenAIResponsesTestFixture.configuration(), models: [model]
    )
    let automatic = try builder.build(
      OpenAIResponsesTestFixture.request(), serverState: nil, localState: nil
    )
    let body = try #require(JSONSerialization.jsonObject(with: automatic.body) as? [String: Any])
    let reasoning = try #require(body["reasoning"] as? [String: Any])
    #expect(reasoning["effort"] as? String == "medium")
    #expect(throws: OpenAIResponsesProviderError.invalidRequest) {
      try builder.build(
        OpenAIResponsesTestFixture.request(options: InferenceOptions(reasoningEffort: .low)),
        serverState: nil, localState: nil
      )
    }
  }

  @Test
  func selectedModelComesFromTheInjectedCatalog() throws {
    let configured = OpenAIResponsesTestFixture.model()
    let selected = ModelDescriptor(
      id: ModelID(rawValue: "gpt-selected"), providerID: configured.providerID,
      displayName: "Selected", capabilities: configured.capabilities
    )
    let request = InferenceRequest(
      providerID: selected.providerID, modelID: selected.id,
      messages: [Message(role: .user, content: [.text("hey")])]
    )
    let builder = OpenAIResponsesRequestBuilder(
      configuration: try OpenAIResponsesTestFixture.configuration(), models: [selected]
    )
    let plan = try builder.build(request, serverState: nil, localState: nil)
    let body = try #require(JSONSerialization.jsonObject(with: plan.body) as? [String: Any])
    #expect(body["model"] as? String == "gpt-selected")
    #expect(throws: OpenAIResponsesProviderError.unsupportedModel) {
      try builder.build(OpenAIResponsesTestFixture.request(), serverState: nil, localState: nil)
    }
  }

  @Test
  func reasoningEffortDoesNotRequireSummarySupport() throws {
    let base = OpenAIResponsesTestFixture.model()
    let model = ModelDescriptor(
      id: base.id, providerID: base.providerID, displayName: base.displayName,
      capabilities: base.capabilities.subtracting([.reasoningSummary]),
      supportedReasoningEfforts: [.low, .high], defaultReasoningEffort: .low
    )
    let plan = try OpenAIResponsesRequestBuilder(
      configuration: OpenAIResponsesTestFixture.configuration(), models: [model]
    ).build(
      OpenAIResponsesTestFixture.request(options: InferenceOptions(reasoningEffort: .high)),
      serverState: nil, localState: nil
    )
    let body = try #require(JSONSerialization.jsonObject(with: plan.body) as? [String: Any])
    let reasoning = try #require(body["reasoning"] as? [String: Any])
    #expect(reasoning["effort"] as? String == "high")
    #expect(reasoning["summary"] == nil)
  }
}
