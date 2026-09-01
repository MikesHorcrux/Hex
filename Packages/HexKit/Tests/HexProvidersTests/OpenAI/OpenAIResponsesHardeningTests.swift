import Foundation
import HexCore
import Testing

@testable import HexProviders

@Suite("OpenAI Responses audit hardening")
struct OpenAIResponsesHardeningTests {
  @Test
  func rejectsForeignAndConsumedServerContinuationIDsBeforeTransport() async throws {
    let foreignTransport = TestOpenAIResponsesTransport(
      responses: [
        OpenAIResponsesTestFixture.response(
          data: try OpenAIResponsesTestFixture.textStream(responseID: "resp_foreign_result")
        )
      ]
    )
    let foreignProvider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-foreign"),
      transport: foreignTransport
    )

    await expectError(.invalidRequest) {
      _ = try await OpenAIResponsesTestFixture.collect(
        provider: foreignProvider,
        request: OpenAIResponsesTestFixture.request(
          previousResponseID: "resp_never_issued",
          messages: [Message(role: .user, content: [.text("Continue")])]
        )
      )
    }
    #expect(await foreignTransport.requests().isEmpty)

    let first = try OpenAIResponsesTestFixture.toolStream(
      responseID: "resp_single_use",
      callID: "call_single_use",
      arguments: "{\"city\":\"Paris\"}"
    )
    let second = try OpenAIResponsesTestFixture.textStream(responseID: "resp_after_tool")
    let transport = TestOpenAIResponsesTransport(
      responses: [
        OpenAIResponsesTestFixture.response(data: first),
        OpenAIResponsesTestFixture.response(data: second),
        OpenAIResponsesTestFixture.response(
          data: try OpenAIResponsesTestFixture.textStream(responseID: "resp_replayed_parent")
        ),
      ]
    )
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-single-use"),
      transport: transport
    )
    let user = Message(role: .user, content: [.text("Weather?")])
    _ = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request(messages: [user], tools: [weatherTool()])
    )
    let call = weatherCall(id: "call_single_use")
    let continuation = OpenAIResponsesTestFixture.request(
      previousResponseID: "resp_single_use",
      messages: [
        user,
        Message(role: .assistant, content: [.toolCall(call)]),
        Message(role: .tool, content: [.toolResult(weatherResult(for: call))]),
      ],
      tools: [weatherTool()]
    )
    _ = try await OpenAIResponsesTestFixture.collect(provider: provider, request: continuation)

    await expectError(.invalidRequest) {
      _ = try await OpenAIResponsesTestFixture.collect(provider: provider, request: continuation)
    }
    #expect(await transport.requests().count == 2)
  }

  @Test
  func rejectsServerContinuationModelAndHistoryLineageMismatch() async throws {
    let alternateModel = ModelDescriptor(
      id: ModelID(rawValue: "gpt-other"),
      providerID: ProviderID(rawValue: "openai"),
      displayName: "GPT Other",
      capabilities: OpenAIResponsesTestFixture.model().capabilities
    )
    let configuration = try OpenAIResponsesConfiguration(
      models: [OpenAIResponsesTestFixture.model(), alternateModel]
    )

    for mismatch in ["history", "model"] {
      let first = try OpenAIResponsesTestFixture.toolStream(
        responseID: "resp_lineage_\(mismatch)",
        callID: "call_lineage_\(mismatch)"
      )
      let transport = TestOpenAIResponsesTransport(
        responses: [
          OpenAIResponsesTestFixture.response(data: first),
          OpenAIResponsesTestFixture.response(
            data: try OpenAIResponsesTestFixture.textStream(responseID: "resp_bad_lineage")
          ),
        ]
      )
      let provider = OpenAIResponsesProvider(
        configuration: configuration,
        credentialProvider: TestOpenAICredentialProvider(key: "sk-lineage"),
        transport: transport
      )
      let original = Message(role: .user, content: [.text("Original")])
      _ = try await OpenAIResponsesTestFixture.collect(
        provider: provider,
        request: OpenAIResponsesTestFixture.request(
          messages: [original],
          tools: [weatherTool()]
        )
      )
      let call = weatherCall(id: "call_lineage_\(mismatch)")
      let firstMessage: Message
      if mismatch == "history" {
        firstMessage = Message(id: original.id, role: .user, content: [.text("Mutated")])
      } else {
        firstMessage = original
      }
      let request = InferenceRequest(
        providerID: ProviderID(rawValue: "openai"),
        modelID: mismatch == "model" ? alternateModel.id : OpenAIResponsesTestFixture.model().id,
        previousProviderResponseID: "resp_lineage_\(mismatch)",
        messages: [
          firstMessage,
          Message(role: .assistant, content: [.toolCall(call)]),
          Message(role: .tool, content: [.toolResult(weatherResult(for: call))]),
        ],
        tools: [weatherTool()]
      )

      await expectError(.invalidRequest) {
        _ = try await OpenAIResponsesTestFixture.collect(provider: provider, request: request)
      }
      #expect(await transport.requests().count == 1)
    }
  }

  @Test
  func neverReissuesConsumedOrEvictedLocalResponseIDs() async throws {
    let transport = TestOpenAIResponsesTransport(
      responses: [
        OpenAIResponsesTestFixture.response(
          data: try OpenAIResponsesTestFixture.toolStream(
            responseID: "resp_local_tombstone",
            callID: "call_first"
          )
        ),
        OpenAIResponsesTestFixture.response(
          data: try OpenAIResponsesTestFixture.toolStream(
            responseID: "resp_retained",
            callID: "call_second"
          )
        ),
        OpenAIResponsesTestFixture.response(
          data: try OpenAIResponsesTestFixture.toolStream(
            responseID: "resp_local_tombstone",
            callID: "call_reissued"
          )
        ),
      ]
    )
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(
        privacyMode: .localEphemeralReplay,
        maximumLocalStates: 1
      ),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-local-tombstone"),
      transport: transport
    )
    _ = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request(
        messages: [Message(role: .user, content: [.text("First")])],
        tools: [weatherTool()]
      )
    )
    _ = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request(
        messages: [Message(role: .user, content: [.text("Second")])],
        tools: [weatherTool()]
      )
    )

    await expectError(.malformedStream) {
      _ = try await OpenAIResponsesTestFixture.collect(
        provider: provider,
        request: OpenAIResponsesTestFixture.request(
          messages: [Message(role: .user, content: [.text("Third")])],
          tools: [weatherTool()]
        )
      )
    }
  }

  @Test
  func rejectsReissuedServerResponseIdentifier() async throws {
    let transport = TestOpenAIResponsesTransport(
      responses: [
        OpenAIResponsesTestFixture.response(
          data: try OpenAIResponsesTestFixture.textStream(responseID: "resp_server_duplicate")
        ),
        OpenAIResponsesTestFixture.response(
          data: try OpenAIResponsesTestFixture.textStream(responseID: "resp_server_duplicate")
        ),
      ]
    )
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-server-duplicate"),
      transport: transport
    )
    _ = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request()
    )

    await expectError(.malformedStream) {
      _ = try await OpenAIResponsesTestFixture.collect(
        provider: provider,
        request: OpenAIResponsesTestFixture.request(
          messages: [Message(role: .user, content: [.text("Unrelated")])]
        )
      )
    }
  }

  @Test
  func issuedIdentifierBoundsFailClosedWithoutForgettingTombstones() async throws {
    for mode in [
      OpenAIResponsesPrivacyMode.serverManagedContinuation,
      .localEphemeralReplay,
    ] {
      let configuration = try OpenAIResponsesConfiguration(
        models: [OpenAIResponsesTestFixture.model()],
        privacyMode: mode,
        maximumIssuedResponseIDs: 1,
        maximumIssuedResponseIDBytes: 64
      )
      let transport = TestOpenAIResponsesTransport(
        responses: [
          OpenAIResponsesTestFixture.response(
            data: try OpenAIResponsesTestFixture.textStream(responseID: "resp_bound_first")
          ),
          OpenAIResponsesTestFixture.response(
            data: try OpenAIResponsesTestFixture.textStream(responseID: "resp_bound_second")
          ),
        ]
      )
      let provider = OpenAIResponsesProvider(
        configuration: configuration,
        credentialProvider: TestOpenAICredentialProvider(key: "sk-id-bound"),
        transport: transport
      )
      _ = try await OpenAIResponsesTestFixture.collect(
        provider: provider,
        request: OpenAIResponsesTestFixture.request()
      )
      await expectError(.continuationStateLimitExceeded) {
        _ = try await OpenAIResponsesTestFixture.collect(
          provider: provider,
          request: OpenAIResponsesTestFixture.request(
            messages: [Message(role: .user, content: [.text("Second")])]
          )
        )
      }
      await expectError(.continuationStateLimitExceeded) {
        _ = try await provider.stream(
          OpenAIResponsesTestFixture.request(
            messages: [Message(role: .user, content: [.text("Third")])]
          )
        )
      }
      #expect(await transport.requests().count == 2)
    }
  }

  @Test
  func enforcesConfiguredDepthAndNodeBoundsBeforeEventDecode() async throws {
    var stream = try OpenAIResponsesTestFixture.textStream(responseID: "resp_json_bounds")
    let original = try #require(String(data: stream, encoding: .utf8))
    let deep = String(repeating: "[", count: 24) + "0" + String(repeating: "]", count: 24)
    let wide = "[" + Array(repeating: "0", count: 128).joined(separator: ",") + "]"
    stream = Data(
      original.replacingOccurrences(
        of: "\"sequence_number\":0",
        with: "\"padding\":{\"deep\":\(deep),\"wide\":\(wide)},\"sequence_number\":0"
      ).utf8
    )
    let configuration = try OpenAIResponsesConfiguration(
      models: [OpenAIResponsesTestFixture.model()],
      maximumJSONDepth: 16,
      maximumJSONNodes: 100
    )
    let provider = OpenAIResponsesProvider(
      configuration: configuration,
      credentialProvider: TestOpenAICredentialProvider(key: "sk-json-structure"),
      transport: TestOpenAIResponsesTransport(
        responses: [OpenAIResponsesTestFixture.response(data: stream)]
      )
    )

    await expectError(.streamLimitExceeded) {
      _ = try await OpenAIResponsesTestFixture.collect(
        provider: provider,
        request: OpenAIResponsesTestFixture.request()
      )
    }
  }

  @Test
  func rejectsContradictoryStableFieldsAndReasoningTextLifecycle() async throws {
    let original = try OpenAIResponsesTestFixture.textStream(responseID: "resp_bad_role")
    var lines = try #require(String(data: original, encoding: .utf8)).components(
      separatedBy: "\n"
    )
    let addedIndex = try #require(
      lines.firstIndex(where: { $0.contains("response.output_item.added") })
    )
    lines[addedIndex] = lines[addedIndex].replacingOccurrences(
      of: "\"role\":\"assistant\"",
      with: "\"role\":\"user\""
    )
    await expectMalformedStream(Data(lines.joined(separator: "\n").utf8))

    await expectMalformedStream(
      try reasoningTextStream(doneTexts: ["different done text"], completedText: "different")
    )
    await expectMalformedStream(
      try reasoningTextStream(
        doneTexts: ["first text", "first text"],
        completedText: "first text"
      )
    )
  }

  @Test
  func continuesMixedAssistantTextAndExactToolCallsInBothPrivacyModes() async throws {
    for mode in [
      OpenAIResponsesPrivacyMode.serverManagedContinuation,
      .localEphemeralReplay,
    ] {
      let transport = TestOpenAIResponsesTransport(
        responses: [
          OpenAIResponsesTestFixture.response(
            data: try mixedTextAndToolStream(
              responseID: "resp_mixed_\(mode)",
              callID: "call_mixed"
            )
          ),
          OpenAIResponsesTestFixture.response(
            data: try OpenAIResponsesTestFixture.textStream(
              responseID: "resp_mixed_done_\(mode)"
            )
          ),
        ]
      )
      let provider = OpenAIResponsesProvider(
        configuration: try OpenAIResponsesTestFixture.configuration(privacyMode: mode),
        credentialProvider: TestOpenAICredentialProvider(key: "sk-mixed"),
        transport: transport
      )
      let user = Message(role: .user, content: [.text("Weather?")])
      _ = try await OpenAIResponsesTestFixture.collect(
        provider: provider,
        request: OpenAIResponsesTestFixture.request(
          messages: [user],
          tools: [weatherTool()]
        )
      )
      let call = weatherCall(id: "call_mixed")
      let continuation = OpenAIResponsesTestFixture.request(
        previousResponseID: "resp_mixed_\(mode)",
        messages: [
          user,
          Message(
            role: .assistant,
            content: [.text("I will check."), .toolCall(call)]
          ),
          Message(role: .tool, content: [.toolResult(weatherResult(for: call))]),
        ],
        tools: [weatherTool()]
      )

      let events = try await OpenAIResponsesTestFixture.collect(
        provider: provider,
        request: continuation
      )
      #expect(events.last == .completed(.stop))
      #expect(await transport.requests().count == 2)
    }
  }

  @Test
  func rejectsWrongMixedAssistantTextAndCallSetBeforeTransport() async throws {
    for mode in [
      OpenAIResponsesPrivacyMode.serverManagedContinuation,
      .localEphemeralReplay,
    ] {
      let responseID = "resp_mirror_\(mode)"
      let transport = TestOpenAIResponsesTransport(
        responses: [
          OpenAIResponsesTestFixture.response(
            data: try mixedTextAndToolStream(
              responseID: responseID,
              callID: "call_expected"
            )
          )
        ]
      )
      let provider = OpenAIResponsesProvider(
        configuration: try OpenAIResponsesTestFixture.configuration(privacyMode: mode),
        credentialProvider: TestOpenAICredentialProvider(key: "sk-mirror"),
        transport: transport
      )
      let user = Message(role: .user, content: [.text("Weather?")])
      _ = try await OpenAIResponsesTestFixture.collect(
        provider: provider,
        request: OpenAIResponsesTestFixture.request(
          messages: [user],
          tools: [weatherTool()]
        )
      )
      let expectedError: OpenAIResponsesProviderError
      if mode == .serverManagedContinuation {
        expectedError = .invalidRequest
      } else {
        expectedError = .localContinuationMismatch
      }
      let expectedCall = weatherCall(id: "call_expected")
      let result = Message(
        role: .tool,
        content: [.toolResult(weatherResult(for: expectedCall))]
      )

      await expectError(expectedError) {
        _ = try await provider.stream(
          OpenAIResponsesTestFixture.request(
            previousResponseID: responseID,
            messages: [
              user,
              Message(
                role: .assistant,
                content: [.text("Wrong text"), .toolCall(expectedCall)]
              ),
              result,
            ],
            tools: [weatherTool()]
          )
        )
      }
      let wrongCall = weatherCall(id: "call_unissued")
      await expectError(expectedError) {
        _ = try await provider.stream(
          OpenAIResponsesTestFixture.request(
            previousResponseID: responseID,
            messages: [
              user,
              Message(
                role: .assistant,
                content: [.text("I will check."), .toolCall(wrongCall)]
              ),
              Message(role: .tool, content: [.toolResult(weatherResult(for: wrongCall))]),
            ],
            tools: [weatherTool()]
          )
        )
      }
      #expect(await transport.requests().count == 1)
    }
  }

  @Test
  func rejectsNestedToolResultImageWithoutModelImageCapability() async throws {
    let model = ModelDescriptor(
      id: ModelID(rawValue: "gpt-text-tool-only"),
      providerID: ProviderID(rawValue: "openai"),
      displayName: "Text Tool Only",
      capabilities: [.textInput, .streaming, .toolCalling]
    )
    let configuration = try OpenAIResponsesConfiguration(models: [model])
    let transport = TestOpenAIResponsesTransport(responses: [])
    let provider = OpenAIResponsesProvider(
      configuration: configuration,
      credentialProvider: TestOpenAICredentialProvider(key: "sk-image-capability"),
      transport: transport
    )
    let call = weatherCall(id: "call_image_capability")
    let imageURL = try #require(URL(string: "data:image/png;base64,iVBORw0KGgo="))
    let result = ToolResult(
      toolCallID: call.id,
      status: .success,
      output: .null,
      content: [.image(ImageContent(sourceURL: imageURL, mediaType: "image/png"))]
    )
    let request = InferenceRequest(
      providerID: configuration.providerID,
      modelID: model.id,
      messages: [
        Message(role: .assistant, content: [.toolCall(call)]),
        Message(role: .tool, content: [.toolResult(result)]),
      ],
      tools: [weatherTool()]
    )

    await expectError(.invalidRequest) {
      _ = try await provider.stream(request)
    }
    #expect(await transport.requests().isEmpty)
  }

  @Test
  func publishesConfiguredLargeToolBatchBeforeCommittingContinuation() async throws {
    let callCount = 4_096
    let responseID = "resp_large_batch"
    let streamData = try largeToolBatchStream(
      responseID: responseID,
      callCount: callCount
    )
    let configuration = try OpenAIResponsesConfiguration(
      models: [OpenAIResponsesTestFixture.model()],
      privacyMode: .localEphemeralReplay,
      maximumSSELineBytes: 1 * 1_024 * 1_024,
      maximumOutputItems: 4_096
    )
    let provider = OpenAIResponsesProvider(
      configuration: configuration,
      credentialProvider: TestOpenAICredentialProvider(key: "sk-large-batch"),
      transport: TestOpenAIResponsesTransport(
        responses: [OpenAIResponsesTestFixture.response(data: streamData)]
      )
    )
    let stream = try await provider.stream(
      OpenAIResponsesTestFixture.request(tools: [weatherTool()])
    )
    try await Task.sleep(for: .milliseconds(500))

    let events = try await stream.consume { cursor in
      var events: [InferenceStreamEvent] = []
      while let event = try await cursor.next() {
        events.append(event)
      }
      return events
    }
    #expect(events.filter(isToolCall).count == callCount)
    #expect(events.last == .completed(.toolCalls))
    #expect(await provider.localStates[responseID] != nil)
  }

  @Test
  func failedTerminalPublicationLeavesNoCommittedContinuation() async throws {
    let responseID = "resp_failed_publication"
    let configuration = try OpenAIResponsesTestFixture.configuration(
      privacyMode: .localEphemeralReplay
    )
    let provider = OpenAIResponsesProvider(
      configuration: configuration,
      credentialProvider: TestOpenAICredentialProvider(key: "sk-publication-failure"),
      transport: TestOpenAIResponsesTransport(responses: [])
    )
    let request = OpenAIResponsesTestFixture.request(tools: [weatherTool()])
    let plan = try OpenAIResponsesRequestBuilder(configuration: configuration).build(
      request,
      serverState: nil,
      localState: nil
    )
    let response = OpenAIResponsesTestFixture.response(
      data: try OpenAIResponsesTestFixture.toolStream(
        responseID: responseID,
        callID: "call_failed_publication",
        includeReasoning: false
      )
    )
    let output = AsyncThrowingStream<InferenceStreamEvent, any Error>.makeStream(
      bufferingPolicy: .bufferingOldest(1)
    )

    await provider.consume(
      response.body,
      request: request,
      plan: plan,
      continuation: output.continuation
    )

    var iterator = output.stream.makeAsyncIterator()
    #expect(try await iterator.next() == .started(providerResponseID: responseID))
    do {
      _ = try await iterator.next()
      Issue.record("Expected the deliberately undersized publication buffer to fail.")
    } catch let error as OpenAIResponsesProviderError {
      #expect(error == .streamLimitExceeded)
    } catch {
      Issue.record("Expected OpenAIResponsesProviderError.streamLimitExceeded.")
    }
    #expect(await provider.localStates[responseID] == nil)
    #expect(await provider.issuedResponseIDs.contains(responseID))
  }

  private func expectMalformedStream(_ data: Data) async {
    do {
      let provider = OpenAIResponsesProvider(
        configuration: try OpenAIResponsesTestFixture.configuration(),
        credentialProvider: TestOpenAICredentialProvider(key: "sk-malformed"),
        transport: TestOpenAIResponsesTransport(
          responses: [OpenAIResponsesTestFixture.response(data: data)]
        )
      )
      _ = try await OpenAIResponsesTestFixture.collect(
        provider: provider,
        request: OpenAIResponsesTestFixture.request()
      )
      Issue.record("Expected malformed stream rejection.")
    } catch let error as OpenAIResponsesProviderError {
      #expect(error == .malformedStream)
    } catch {
      Issue.record("Expected OpenAIResponsesProviderError.malformedStream.")
    }
  }

  private func expectError(
    _ expected: OpenAIResponsesProviderError,
    operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      Issue.record("Expected OpenAI Responses provider rejection.")
    } catch let error as OpenAIResponsesProviderError {
      #expect(error == expected)
    } catch {
      Issue.record("Expected a redacted OpenAIResponsesProviderError.")
    }
  }

  private func weatherTool() -> ToolDefinition {
    ToolDefinition(
      name: "lookup_weather",
      description: "Look up weather.",
      inputSchema: ["type": .string("object")]
    )
  }

  private func weatherCall(id: String) -> ToolCall {
    ToolCall(
      id: ToolCallID(rawValue: id),
      name: "lookup_weather",
      arguments: ["city": .string("Paris")]
    )
  }

  private func weatherResult(for call: ToolCall) -> ToolResult {
    ToolResult(
      toolCallID: call.id,
      status: .success,
      output: .object(["temperature": .integer(18)])
    )
  }

  private func isToolCall(_ event: InferenceStreamEvent) -> Bool {
    if case .toolCall = event { return true }
    return false
  }

  private func reasoningTextStream(
    doneTexts: [String],
    completedText: String
  ) throws -> Data {
    let responseID = "resp_reasoning_text"
    let itemID = "rs_reasoning_text"
    let added: [String: Any] = [
      "id": itemID,
      "type": "reasoning",
      "summary": [],
      "content": [],
    ]
    let completed: [String: Any] = [
      "id": itemID,
      "type": "reasoning",
      "summary": [],
      "content": [["type": "reasoning_text", "text": completedText]],
      "status": "completed",
    ]
    var data = Data()
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.created",
        "sequence_number": 0,
        "response": ["id": responseID, "status": "in_progress"],
      ],
      to: &data
    )
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.output_item.added",
        "sequence_number": 1,
        "output_index": 0,
        "item": added,
      ],
      to: &data
    )
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.reasoning_text.delta",
        "sequence_number": 2,
        "item_id": itemID,
        "output_index": 0,
        "content_index": 0,
        "delta": "first text",
      ],
      to: &data
    )
    var sequence = 3
    for text in doneTexts {
      try OpenAIResponsesTestFixture.appendEvent(
        [
          "type": "response.reasoning_text.done",
          "sequence_number": sequence,
          "item_id": itemID,
          "output_index": 0,
          "content_index": 0,
          "text": text,
        ],
        to: &data
      )
      sequence += 1
    }
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.output_item.done",
        "sequence_number": sequence,
        "output_index": 0,
        "item": completed,
      ],
      to: &data
    )
    sequence += 1
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.completed",
        "sequence_number": sequence,
        "response": [
          "id": responseID,
          "status": "completed",
          "output": [completed],
          "usage": ["input_tokens": 1, "output_tokens": 1],
        ],
      ],
      to: &data
    )
    return data
  }

  private func mixedTextAndToolStream(responseID: String, callID: String) throws -> Data {
    let messageAdded: [String: Any] = [
      "id": "msg_\(responseID)",
      "type": "message",
      "status": "in_progress",
      "role": "assistant",
      "content": [],
    ]
    let messageDone: [String: Any] = [
      "id": "msg_\(responseID)",
      "type": "message",
      "status": "completed",
      "role": "assistant",
      "content": [["type": "output_text", "text": "I will check.", "annotations": []]],
    ]
    let callAdded: [String: Any] = [
      "id": "fc_\(responseID)",
      "type": "function_call",
      "call_id": callID,
      "name": "lookup_weather",
      "arguments": "",
      "status": "in_progress",
    ]
    let callDone: [String: Any] = [
      "id": "fc_\(responseID)",
      "type": "function_call",
      "call_id": callID,
      "name": "lookup_weather",
      "arguments": "{\"city\":\"Paris\"}",
      "status": "completed",
    ]
    var data = Data()
    var sequence = 0
    try append([
      "type": "response.created",
      "response": ["id": responseID, "status": "in_progress"],
    ])
    try append(["type": "response.output_item.added", "output_index": 0, "item": messageAdded])
    try append([
      "type": "response.content_part.added",
      "item_id": "msg_\(responseID)",
      "output_index": 0,
      "content_index": 0,
      "part": ["type": "output_text", "text": "", "annotations": []],
    ])
    try append([
      "type": "response.output_text.delta", "item_id": "msg_\(responseID)",
      "output_index": 0, "content_index": 0, "delta": "I will check.",
    ])
    try append([
      "type": "response.output_text.done", "item_id": "msg_\(responseID)",
      "output_index": 0, "content_index": 0, "text": "I will check.",
    ])
    try append([
      "type": "response.content_part.done", "item_id": "msg_\(responseID)",
      "output_index": 0, "content_index": 0,
      "part": ["type": "output_text", "text": "I will check.", "annotations": []],
    ])
    try append(["type": "response.output_item.done", "output_index": 0, "item": messageDone])
    try append(["type": "response.output_item.added", "output_index": 1, "item": callAdded])
    try append([
      "type": "response.function_call_arguments.delta", "item_id": "fc_\(responseID)",
      "output_index": 1, "delta": "{\"city\":\"Paris\"}",
    ])
    try append([
      "type": "response.function_call_arguments.done", "item_id": "fc_\(responseID)",
      "output_index": 1, "call_id": callID, "name": "lookup_weather",
      "arguments": "{\"city\":\"Paris\"}",
    ])
    try append(["type": "response.output_item.done", "output_index": 1, "item": callDone])
    try append([
      "type": "response.completed",
      "response": [
        "id": responseID,
        "status": "completed",
        "output": [messageDone, callDone],
        "usage": ["input_tokens": 5, "output_tokens": 5],
      ],
    ])
    data.append(Data("data: [DONE]\n\n".utf8))
    return data

    func append(_ event: [String: Any]) throws {
      var event = event
      event["sequence_number"] = sequence
      sequence += 1
      try OpenAIResponsesTestFixture.appendEvent(event, to: &data)
    }
  }

  private func largeToolBatchStream(responseID: String, callCount: Int) throws -> Data {
    var data = Data()
    var sequence = 0
    var output: [[String: Any]] = []
    try append([
      "type": "response.created",
      "response": ["id": responseID, "status": "in_progress"],
    ])
    for index in 0..<callCount {
      let itemID = "fc_\(index)"
      let callID = "call_\(index)"
      let added: [String: Any] = [
        "id": itemID, "type": "function_call", "call_id": callID,
        "name": "lookup_weather", "arguments": "", "status": "in_progress",
      ]
      let done: [String: Any] = [
        "id": itemID, "type": "function_call", "call_id": callID,
        "name": "lookup_weather", "arguments": "{}", "status": "completed",
      ]
      output.append(done)
      try append(["type": "response.output_item.added", "output_index": index, "item": added])
      try append([
        "type": "response.function_call_arguments.done", "item_id": itemID,
        "output_index": index, "call_id": callID, "name": "lookup_weather",
        "arguments": "{}",
      ])
      try append(["type": "response.output_item.done", "output_index": index, "item": done])
    }
    try append([
      "type": "response.completed",
      "response": [
        "id": responseID, "status": "completed", "output": output,
        "usage": ["input_tokens": 1, "output_tokens": 1],
      ],
    ])
    return data

    func append(_ event: [String: Any]) throws {
      var event = event
      event["sequence_number"] = sequence
      sequence += 1
      try OpenAIResponsesTestFixture.appendEvent(event, to: &data)
    }
  }
}
