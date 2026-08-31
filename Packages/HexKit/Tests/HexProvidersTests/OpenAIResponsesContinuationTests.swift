import Foundation
import HexCore
import Testing

@testable import HexProviders

@Suite("OpenAI Responses continuation state")
struct OpenAIResponsesContinuationTests {
  @Test
  func usesCanonicalSHA256HistoryFingerprints() throws {
    let original = Message(role: .user, content: [.text("Original")])
    let changed = Message(id: original.id, role: .user, content: [.text("Changed")])
    let originalFingerprint = try OpenAIMessageFingerprint.make(for: original)
    let changedFingerprint = try OpenAIMessageFingerprint.make(for: changed)

    #expect(originalFingerprint.digest.count == 32)
    #expect(changedFingerprint.digest.count == 32)
    #expect(originalFingerprint != changedFingerprint)
  }

  @Test
  func evictsOldestBoundedLocalStateAndFailsMissingContinuationClosed() async throws {
    let first = try OpenAIResponsesTestFixture.toolStream(
      responseID: "resp_evicted",
      callID: "call_evicted"
    )
    let second = try OpenAIResponsesTestFixture.toolStream(
      responseID: "resp_retained",
      callID: "call_retained"
    )
    let transport = TestOpenAIResponsesTransport(
      responses: [
        OpenAIResponsesTestFixture.response(data: first),
        OpenAIResponsesTestFixture.response(data: second),
      ]
    )
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(
        privacyMode: .localEphemeralReplay,
        maximumLocalStates: 1
      ),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-eviction"),
      transport: transport
    )
    let firstMessage = Message(role: .user, content: [.text("First")])
    let secondMessage = Message(role: .user, content: [.text("Second")])
    _ = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request(messages: [firstMessage], tools: [weatherTool()])
    )
    _ = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request(messages: [secondMessage], tools: [weatherTool()])
    )

    let evictedCall = weatherCall(id: "call_evicted", city: "Zürich")
    let continuation = OpenAIResponsesTestFixture.request(
      previousResponseID: "resp_evicted",
      messages: [
        firstMessage,
        Message(role: .assistant, content: [.toolCall(evictedCall)]),
        Message(role: .tool, content: [.toolResult(weatherResult(for: evictedCall))]),
      ],
      tools: [weatherTool()]
    )

    do {
      _ = try await provider.stream(continuation)
      Issue.record("Expected evicted continuation state to fail closed.")
    } catch let error as OpenAIResponsesProviderError {
      #expect(error == .missingLocalContinuation)
    } catch {
      Issue.record("Expected a provider error.")
    }
    #expect(await transport.requests().count == 2)
  }

  @Test
  func rejectsLocalContinuationStateBeyondByteBudget() async throws {
    let streamData = try OpenAIResponsesTestFixture.toolStream(
      responseID: "resp_state_bytes",
      callID: "call_state_bytes",
      includeReasoning: false
    )
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(
        privacyMode: .localEphemeralReplay,
        maximumLocalStateBytes: 1_024,
        maximumLocalCacheBytes: 1_024
      ),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-state-bytes"),
      transport: TestOpenAIResponsesTransport(
        responses: [OpenAIResponsesTestFixture.response(data: streamData)]
      )
    )

    do {
      _ = try await OpenAIResponsesTestFixture.collect(
        provider: provider,
        request: OpenAIResponsesTestFixture.request(
          messages: (0..<20).map { index in
            Message(role: .user, content: [.text("Message \(index)")])
          },
          tools: [weatherTool()]
        )
      )
      Issue.record("Expected bounded local continuation state to fail closed.")
    } catch let error as OpenAIResponsesProviderError {
      #expect(error == .localStateLimitExceeded)
    } catch {
      Issue.record("Expected OpenAIResponsesProviderError.localStateLimitExceeded.")
    }
  }

  @Test
  func rejectsMismatchedNeutralHistoryBeforeTransport() async throws {
    let first = try OpenAIResponsesTestFixture.toolStream(
      responseID: "resp_history",
      callID: "call_history"
    )
    let transport = TestOpenAIResponsesTransport(
      responses: [OpenAIResponsesTestFixture.response(data: first)]
    )
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(
        privacyMode: .localEphemeralReplay
      ),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-history"),
      transport: transport
    )
    let original = Message(role: .user, content: [.text("Original")])
    _ = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request(messages: [original], tools: [weatherTool()])
    )

    let call = weatherCall(id: "call_history", city: "Zürich")
    let mismatched = OpenAIResponsesTestFixture.request(
      previousResponseID: "resp_history",
      messages: [
        Message(role: .user, content: [.text("Changed identity")]),
        Message(role: .assistant, content: [.toolCall(call)]),
        Message(role: .tool, content: [.toolResult(weatherResult(for: call))]),
      ],
      tools: [weatherTool()]
    )

    do {
      _ = try await provider.stream(mismatched)
      Issue.record("Expected mismatched local history to fail closed.")
    } catch let error as OpenAIResponsesProviderError {
      #expect(error == .localContinuationMismatch)
    } catch {
      Issue.record("Expected a provider error.")
    }
    #expect(await transport.requests().count == 1)
  }

  @Test
  func rejectsResponseIDReuseWithoutOverwritingConsumedState() async throws {
    let first = try OpenAIResponsesTestFixture.toolStream(
      responseID: "resp_reused",
      callID: "call_first"
    )
    let reused = try OpenAIResponsesTestFixture.toolStream(
      responseID: "resp_reused",
      callID: "call_second",
      arguments: "{\"city\":\"Paris\"}"
    )
    let transport = TestOpenAIResponsesTransport(
      responses: [
        OpenAIResponsesTestFixture.response(data: first),
        OpenAIResponsesTestFixture.response(data: reused),
      ]
    )
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(
        privacyMode: .localEphemeralReplay
      ),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-reused-id"),
      transport: transport
    )
    let user = Message(role: .user, content: [.text("Compare weather")])
    _ = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request(messages: [user], tools: [weatherTool()])
    )

    let call = weatherCall(id: "call_first", city: "Zürich")
    let continuation = OpenAIResponsesTestFixture.request(
      previousResponseID: "resp_reused",
      messages: [
        user,
        Message(role: .assistant, content: [.toolCall(call)]),
        Message(role: .tool, content: [.toolResult(weatherResult(for: call))]),
      ],
      tools: [weatherTool()]
    )

    do {
      _ = try await OpenAIResponsesTestFixture.collect(provider: provider, request: continuation)
      Issue.record("Expected a reused provider response ID to fail closed.")
    } catch let error as OpenAIResponsesProviderError {
      #expect(error == .malformedStream)
    } catch {
      Issue.record("Expected OpenAIResponsesProviderError.malformedStream.")
    }
    #expect(await transport.requests().count == 2)
  }

  @Test
  func rejectsFinalResponseIDCollidingWithExistingLocalState() async throws {
    let retained = try OpenAIResponsesTestFixture.toolStream(
      responseID: "resp_collision",
      callID: "call_collision"
    )
    let collidingFinal = try OpenAIResponsesTestFixture.textStream(
      responseID: "resp_collision"
    )
    let transport = TestOpenAIResponsesTransport(
      responses: [
        OpenAIResponsesTestFixture.response(data: retained),
        OpenAIResponsesTestFixture.response(data: collidingFinal),
      ]
    )
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(
        privacyMode: .localEphemeralReplay
      ),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-collision"),
      transport: transport
    )
    _ = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request(tools: [weatherTool()])
    )

    do {
      _ = try await OpenAIResponsesTestFixture.collect(
        provider: provider,
        request: OpenAIResponsesTestFixture.request(
          messages: [Message(role: .user, content: [.text("Unrelated request")])]
        )
      )
      Issue.record("Expected local response ID collision to fail closed.")
    } catch let error as OpenAIResponsesProviderError {
      #expect(error == .malformedStream)
    } catch {
      Issue.record("Expected OpenAIResponsesProviderError.malformedStream.")
    }
    #expect(await transport.requests().count == 2)
  }

  @Test
  func replaysMultipleOpaqueToolRoundsInProviderOrder() async throws {
    let first = try OpenAIResponsesTestFixture.toolStream(
      responseID: "resp_round_1",
      callID: "call_round_1"
    )
    let second = try OpenAIResponsesTestFixture.toolStream(
      responseID: "resp_round_2",
      callID: "call_round_2",
      arguments: "{\"city\":\"Paris\"}"
    )
    let final = try OpenAIResponsesTestFixture.textStream(responseID: "resp_round_3")
    let transport = TestOpenAIResponsesTransport(
      responses: [
        OpenAIResponsesTestFixture.response(data: first),
        OpenAIResponsesTestFixture.response(data: second),
        OpenAIResponsesTestFixture.response(data: final),
      ]
    )
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(
        privacyMode: .localEphemeralReplay
      ),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-rounds"),
      transport: transport
    )
    let user = Message(role: .user, content: [.text("Compare two cities")])
    _ = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request(messages: [user], tools: [weatherTool()])
    )

    let firstCall = weatherCall(id: "call_round_1", city: "Zürich")
    let firstToolMessage = Message(
      role: .tool,
      content: [.toolResult(weatherResult(for: firstCall))]
    )
    let firstContinuationMessages = [
      user,
      Message(role: .assistant, content: [.toolCall(firstCall)]),
      firstToolMessage,
    ]
    _ = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request(
        previousResponseID: "resp_round_1",
        messages: firstContinuationMessages,
        tools: [weatherTool()]
      )
    )

    let secondCall = weatherCall(id: "call_round_2", city: "Paris")
    let secondContinuationMessages =
      firstContinuationMessages + [
        Message(role: .assistant, content: [.toolCall(secondCall)]),
        Message(role: .tool, content: [.toolResult(weatherResult(for: secondCall))]),
      ]
    _ = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request(
        previousResponseID: "resp_round_2",
        messages: secondContinuationMessages,
        tools: [weatherTool()]
      )
    )

    let requests = await transport.requests()
    #expect(requests.count == 3)
    let thirdBody = try OpenAIResponsesTestFixture.jsonObject(from: requests[2])
    #expect(thirdBody["previous_response_id"] == nil)
    let input = try #require(thirdBody["input"] as? [[String: Any]])
    #expect(
      input.map { $0["type"] as? String } == [
        "message",
        "reasoning",
        "function_call",
        "function_call_output",
        "reasoning",
        "function_call",
        "function_call_output",
      ])
    #expect(input.filter { $0["type"] as? String == "function_call" }.count == 2)
    #expect(input.filter { $0["type"] as? String == "function_call_output" }.count == 2)
  }

  @Test
  func serverManagedUserFollowUpSendsOnlyLatestUserItem() async throws {
    let first = try OpenAIResponsesTestFixture.textStream(responseID: "resp_user_1")
    let second = try OpenAIResponsesTestFixture.textStream(responseID: "resp_user_2")
    let transport = TestOpenAIResponsesTransport(
      responses: [
        OpenAIResponsesTestFixture.response(data: first),
        OpenAIResponsesTestFixture.response(data: second),
      ]
    )
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-user-follow-up"),
      transport: transport
    )
    let firstUser = Message(role: .user, content: [.text("First question")])
    _ = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request(messages: [firstUser])
    )

    let assistant = Message(role: .assistant, content: [.text("First answer")])
    let secondUser = Message(role: .user, content: [.text("Follow up")])
    _ = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request(
        previousResponseID: "resp_user_1",
        messages: [firstUser, assistant, secondUser]
      )
    )

    let requests = await transport.requests()
    let body = try OpenAIResponsesTestFixture.jsonObject(from: requests[1])
    #expect(body["previous_response_id"] as? String == "resp_user_1")
    let input = try #require(body["input"] as? [[String: Any]])
    #expect(input.count == 1)
    #expect(input[0]["role"] as? String == "user")
    let content = try #require(input[0]["content"] as? [[String: Any]])
    #expect(content[0]["text"] as? String == "Follow up")
  }

  private func weatherTool() -> ToolDefinition {
    ToolDefinition(
      name: "lookup_weather",
      description: "Look up weather for a city.",
      inputSchema: ["type": .string("object")]
    )
  }

  private func weatherCall(id: String, city: String) -> ToolCall {
    ToolCall(
      id: ToolCallID(rawValue: id),
      name: "lookup_weather",
      arguments: ["city": .string(city)]
    )
  }

  private func weatherResult(for call: ToolCall) -> ToolResult {
    ToolResult(
      toolCallID: call.id,
      status: .success,
      output: .object(["temperature": .integer(18)])
    )
  }
}
