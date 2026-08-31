import Foundation
import HexCore
import Testing

@testable import HexProviders

@Suite("OpenAI Responses hostile audit v5")
struct OpenAIResponsesAuditV5Tests {
  @Test
  func rejectsTextOnlySuccessForForcedToolChoicesBeforeTerminalPublicationOrCommit() async throws {
    for mode in modes {
      for (label, toolChoice) in forcedToolChoices {
        let responseID = "resp_forced_\(label)_\(mode.rawValue)"
        let result = await collect(
          try OpenAIResponsesTestFixture.textStream(responseID: responseID),
          configuration: try configuration(privacyMode: mode),
          tools: [weatherTool],
          toolChoice: toolChoice
        )

        #expect(result.error == .malformedStream)
        #expect(!result.events.contains(where: isTerminalPublication))
        await expectNoContinuationCommit(result.provider, responseID: responseID)
      }
    }
  }

  @Test
  func rejectsMultipleCallsWhenModelDisallowsParallelToolsBeforePublicationOrCommit() async throws {
    for mode in modes {
      let responseID = "resp_nonparallel_\(mode.rawValue)"
      let transport = TestOpenAIResponsesTransport(
        responses: [
          OpenAIResponsesTestFixture.response(
            data: try twoToolCallStream(responseID: responseID)
          )
        ]
      )
      let provider = OpenAIResponsesProvider(
        configuration: try configuration(privacyMode: mode, allowsParallelTools: false),
        credentialProvider: TestOpenAICredentialProvider(key: "sk-nonparallel-audit"),
        transport: transport
      )
      let result = await collect(
        provider: provider,
        tools: [weatherTool],
        toolChoice: .automatic
      )

      let requests = await transport.requests()
      let request = try #require(requests.first)
      let body = try OpenAIResponsesTestFixture.jsonObject(from: request)
      #expect(body["parallel_tool_calls"] as? Bool == false)
      #expect(result.error == .malformedStream)
      #expect(!result.events.contains(where: isTerminalPublication))
      await expectNoContinuationCommit(result.provider, responseID: responseID)
    }
  }

  @Test
  func rejectsUsageSubsetsLargerThanTheirTotalsBeforePublicationOrCommit() async throws {
    let violations = [
      (label: "cached", original: "\"cached_tokens\":2", replacement: "\"cached_tokens\":13"),
      (
        label: "reasoning",
        original: "\"reasoning_tokens\":1",
        replacement: "\"reasoning_tokens\":4"
      ),
    ]

    for mode in modes {
      for violation in violations {
        let responseID = "resp_usage_\(violation.label)_\(mode.rawValue)"
        let validData = try OpenAIResponsesTestFixture.textStream(responseID: responseID)
        let validText = try #require(String(data: validData, encoding: .utf8))
        #expect(validText.contains(violation.original))
        let invalidData = Data(
          validText.replacingOccurrences(
            of: violation.original,
            with: violation.replacement
          ).utf8
        )
        let result = await collect(
          invalidData,
          configuration: try configuration(privacyMode: mode)
        )

        #expect(result.error == .malformedStream)
        #expect(!result.events.contains(where: isTerminalPublication))
        await expectNoContinuationCommit(result.provider, responseID: responseID)
      }
    }
  }

  @Test
  func acceptsBareCRAndCRLFAcrossEveryByteBoundaryWithoutBreakingUTF8() async throws {
    let expectedText = "Grüße 👋"
    for mode in modes {
      for (label, lineEnding) in [("cr", "\r"), ("crlf", "\r\n")] {
        let responseID = "resp_\(label)_framing_\(mode.rawValue)"
        let data = try OpenAIResponsesTestFixture.textStream(
          responseID: responseID,
          text: expectedText,
          lineEnding: lineEnding,
          decorateDelta: true
        )
        let provider = OpenAIResponsesProvider(
          configuration: try configuration(privacyMode: mode),
          credentialProvider: TestOpenAICredentialProvider(key: "sk-framing-audit"),
          transport: TestOpenAIResponsesTransport(
            responses: [
              OpenAIResponsesTestFixture.response(
                data: data,
                splitAt: Array(1..<data.count)
              )
            ]
          )
        )

        let events = try await OpenAIResponsesTestFixture.collect(
          provider: provider,
          request: OpenAIResponsesTestFixture.request()
        )
        #expect(
          events == [
            .started(providerResponseID: responseID),
            .textDelta(expectedText),
            .usage(
              InferenceUsage(
                inputTokens: 12,
                outputTokens: 3,
                cachedInputTokens: 2,
                reasoningTokens: 1
              )
            ),
            .completed(.stop),
          ]
        )
      }
    }
  }

  private let modes: [OpenAIResponsesPrivacyMode] = [
    .serverManagedContinuation,
    .localEphemeralReplay,
  ]

  private var forcedToolChoices: [(String, ToolChoice)] {
    [
      ("required", .required),
      ("named", .named("lookup_weather")),
    ]
  }

  private var weatherTool: ToolDefinition {
    ToolDefinition(
      name: "lookup_weather",
      description: "Look up weather.",
      inputSchema: ["type": .string("object")]
    )
  }

  private func configuration(
    privacyMode: OpenAIResponsesPrivacyMode,
    allowsParallelTools: Bool = true
  ) throws -> OpenAIResponsesConfiguration {
    var capabilities: Set<InferenceCapability> = [
      .textInput,
      .streaming,
      .toolCalling,
    ]
    if allowsParallelTools {
      capabilities.insert(.parallelToolCalling)
    }
    let model = ModelDescriptor(
      id: ModelID(rawValue: "gpt-test"),
      providerID: ProviderID(rawValue: "openai"),
      displayName: "GPT Test",
      capabilities: capabilities,
      contextWindow: 32_000,
      maxOutputTokens: 4_096
    )
    return try OpenAIResponsesConfiguration(
      endpoint: URL(string: "https://api.openai.com/v1/responses"),
      models: [model],
      privacyMode: privacyMode
    )
  }

  private func collect(
    _ data: Data,
    configuration: OpenAIResponsesConfiguration,
    tools: [ToolDefinition] = [],
    toolChoice: ToolChoice = .automatic
  ) async -> AuditResult {
    let provider = OpenAIResponsesProvider(
      configuration: configuration,
      credentialProvider: TestOpenAICredentialProvider(key: "sk-hostile-audit-v5"),
      transport: TestOpenAIResponsesTransport(
        responses: [OpenAIResponsesTestFixture.response(data: data)]
      )
    )
    return await collect(provider: provider, tools: tools, toolChoice: toolChoice)
  }

  private func collect(
    provider: OpenAIResponsesProvider,
    tools: [ToolDefinition],
    toolChoice: ToolChoice
  ) async -> AuditResult {
    var events: [InferenceStreamEvent] = []
    do {
      let stream = try await provider.stream(
        OpenAIResponsesTestFixture.request(tools: tools, toolChoice: toolChoice)
      )
      for try await event in stream {
        events.append(event)
      }
      return AuditResult(events: events, error: nil, provider: provider)
    } catch let error as OpenAIResponsesProviderError {
      return AuditResult(events: events, error: error, provider: provider)
    } catch {
      Issue.record("Unexpected error type: \(error)")
      return AuditResult(events: events, error: nil, provider: provider)
    }
  }

  private func expectNoContinuationCommit(
    _ provider: OpenAIResponsesProvider?,
    responseID: String
  ) async {
    guard let provider else {
      Issue.record("Expected the provider to be available for state inspection.")
      return
    }
    #expect(await provider.serverStates[responseID] == nil)
    #expect(await provider.localStates[responseID] == nil)
    let serverStateOrder = await provider.serverStateOrder
    let localStateOrder = await provider.localStateOrder
    #expect(!serverStateOrder.contains(responseID))
    #expect(!localStateOrder.contains(responseID))
  }

  private func isTerminalPublication(_ event: InferenceStreamEvent) -> Bool {
    switch event {
    case .toolCall, .usage, .completed:
      true
    case .started, .textDelta, .reasoningSummaryDelta:
      false
    }
  }

  private func twoToolCallStream(responseID: String) throws -> Data {
    let completedItems = (0..<2).map { index in
      toolItem(responseID: responseID, index: index, status: "completed")
    }
    var data = Data()
    var sequence = 0
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.created",
        "sequence_number": sequence,
        "response": ["id": responseID, "status": "in_progress"],
      ],
      to: &data
    )
    sequence += 1

    for index in 0..<2 {
      try OpenAIResponsesTestFixture.appendEvent(
        [
          "type": "response.output_item.added",
          "sequence_number": sequence,
          "output_index": index,
          "item": toolItem(responseID: responseID, index: index, status: "in_progress"),
        ],
        to: &data
      )
      sequence += 1
      let completedItem = completedItems[index]
      let arguments = try #require(completedItem["arguments"] as? String)
      try OpenAIResponsesTestFixture.appendEvent(
        [
          "type": "response.function_call_arguments.done",
          "sequence_number": sequence,
          "item_id": "fc_\(responseID)_\(index)",
          "output_index": index,
          "call_id": "call_\(responseID)_\(index)",
          "name": "lookup_weather",
          "arguments": arguments,
        ],
        to: &data
      )
      sequence += 1
      try OpenAIResponsesTestFixture.appendEvent(
        [
          "type": "response.output_item.done",
          "sequence_number": sequence,
          "output_index": index,
          "item": completedItem,
        ],
        to: &data
      )
      sequence += 1
    }

    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.completed",
        "sequence_number": sequence,
        "response": [
          "id": responseID,
          "status": "completed",
          "output": completedItems,
          "usage": ["input_tokens": 20, "output_tokens": 8],
        ],
      ],
      to: &data
    )
    data.append(Data("data: [DONE]\n\n".utf8))
    return data
  }

  private func toolItem(
    responseID: String,
    index: Int,
    status: String
  ) -> [String: Any] {
    [
      "id": "fc_\(responseID)_\(index)",
      "type": "function_call",
      "call_id": "call_\(responseID)_\(index)",
      "name": "lookup_weather",
      "arguments": status == "completed" ? "{\"city\":\"City \(index)\"}" : "",
      "status": status,
    ]
  }

  private struct AuditResult: Sendable {
    let events: [InferenceStreamEvent]
    let error: OpenAIResponsesProviderError?
    let provider: OpenAIResponsesProvider?
  }
}
