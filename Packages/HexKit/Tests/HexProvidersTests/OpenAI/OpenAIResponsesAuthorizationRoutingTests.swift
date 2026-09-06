import Foundation
import HexCore
import Testing

@testable import HexProviders

@Suite("OpenAI Responses authorization routing")
struct OpenAIResponsesAuthorizationRoutingTests {
  @Test
  func chatGPTSubscriptionIgnoresBoundedMetadataEventsWithoutSequenceNumbers() async throws {
    let ordinaryStream = try OpenAIResponsesTestFixture.textStream(text: "online")
    let eventBoundary = try #require(ordinaryStream.range(of: Data("\n\n".utf8)))
    var responseData = Data(ordinaryStream[..<eventBoundary.upperBound])
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.metadata",
        "metadata": ["presentation": "inline"],
      ],
      to: &responseData
    )
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "codex.response.metadata",
        "metadata": ["source": "subscription"],
      ],
      to: &responseData
    )
    responseData.append(ordinaryStream[eventBoundary.upperBound...])

    let transport = TestOpenAIResponsesTransport(
      responses: [
        OpenAIResponsesTestFixture.response(data: responseData, contentType: nil)
      ]
    )
    let configuration = try OpenAIResponsesConfiguration(
      service: .chatGPTCodexSubscription,
      models: [OpenAIResponsesTestFixture.model()]
    )
    let provider = OpenAIResponsesProvider(
      configuration: configuration,
      authorizationProvider: StaticAuthorizationProvider(
        value: OpenAIResponsesAuthorization(
          bearerToken: "subscription-access-token",
          accountID: "account-test"
        )
      ),
      transport: transport
    )

    let events = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request()
    )
    #expect(events.contains(.textDelta("online")))
  }

  @Test
  func chatGPTSubscriptionAcceptsAValidEventLargerThanSixtyFourKilobytes() async throws {
    let ordinaryStream = try OpenAIResponsesTestFixture.textStream(text: "online")
    let eventBoundary = try #require(ordinaryStream.range(of: Data("\n\n".utf8)))
    var responseData = Data()
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.created",
        "sequence_number": 0,
        "response": [
          "id": "resp_text",
          "status": "in_progress",
          "provider_metadata": String(repeating: "x", count: 96 * 1_024),
        ],
      ],
      to: &responseData
    )
    responseData.append(ordinaryStream[eventBoundary.upperBound...])

    let transport = TestOpenAIResponsesTransport(
      responses: [
        OpenAIResponsesTestFixture.response(data: responseData, contentType: nil)
      ]
    )
    let configuration = try OpenAIResponsesConfiguration(
      service: .chatGPTCodexSubscription,
      models: [OpenAIResponsesTestFixture.model()]
    )
    let provider = OpenAIResponsesProvider(
      configuration: configuration,
      authorizationProvider: StaticAuthorizationProvider(
        value: OpenAIResponsesAuthorization(
          bearerToken: "subscription-access-token",
          accountID: "account-test"
        )
      ),
      transport: transport
    )

    let events = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request()
    )
    #expect(events.contains(.textDelta("online")))
  }

  @Test
  func chatGPTSubscriptionAcceptsAValidEventStreamWithoutAContentTypeHeader() async throws {
    let responseData = try OpenAIResponsesTestFixture.textStream(text: "online")
    let transport = TestOpenAIResponsesTransport(
      responses: [
        OpenAIResponsesTestFixture.response(data: responseData, contentType: nil)
      ]
    )
    let configuration = try OpenAIResponsesConfiguration(
      service: .chatGPTCodexSubscription,
      models: [OpenAIResponsesTestFixture.model()]
    )
    let provider = OpenAIResponsesProvider(
      configuration: configuration,
      authorizationProvider: StaticAuthorizationProvider(
        value: OpenAIResponsesAuthorization(
          bearerToken: "subscription-access-token",
          accountID: "account-test"
        )
      ),
      transport: transport
    )

    let events = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request()
    )
    #expect(events.contains(.textDelta("online")))
  }

  @Test
  func chatGPTSubscriptionUsesValidatedStreamedItemsWhenTerminalSnapshotIsOmitted() async throws {
    let responseData = try OpenAIResponsesTestFixture.textStream(
      text: "online",
      omitsTerminalOutput: true
    )
    let transport = TestOpenAIResponsesTransport(
      responses: [
        OpenAIResponsesTestFixture.response(data: responseData, contentType: nil)
      ]
    )
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesConfiguration(
        service: .chatGPTCodexSubscription,
        models: [OpenAIResponsesTestFixture.model()]
      ),
      authorizationProvider: StaticAuthorizationProvider(
        value: OpenAIResponsesAuthorization(
          bearerToken: "subscription-access-token",
          accountID: "account-test"
        )
      ),
      transport: transport
    )

    let events = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request()
    )

    #expect(events.contains(.textDelta("online")))
    #expect(events.last == .completed(.stop))
  }

  @Test
  func platformAPIRejectsAnOmittedTerminalSnapshot() async throws {
    let responseData = try OpenAIResponsesTestFixture.textStream(
      text: "online",
      omitsTerminalOutput: true
    )
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesConfiguration(
        service: .platformAPI,
        models: [OpenAIResponsesTestFixture.model()]
      ),
      authorizationProvider: StaticAuthorizationProvider(
        value: OpenAIResponsesAuthorization(bearerToken: "platform-api-key")
      ),
      transport: TestOpenAIResponsesTransport(
        responses: [OpenAIResponsesTestFixture.response(data: responseData)]
      )
    )

    do {
      _ = try await OpenAIResponsesTestFixture.collect(
        provider: provider,
        request: OpenAIResponsesTestFixture.request()
      )
      Issue.record("Expected the public Responses API route to require its terminal snapshot.")
    } catch let error as OpenAIResponsesProviderError {
      #expect(error == .malformedStream)
    }
  }

  @Test
  func chatGPTSubscriptionReplaysOmittedTerminalToolItemsWithoutProviderItemIDs() async throws {
    let firstResponse = try OpenAIResponsesTestFixture.toolStream(
      responseID: "resp_subscription_tool",
      callID: "call_subscription_tool",
      omitsTerminalOutput: true
    )
    let secondResponse = try OpenAIResponsesTestFixture.textStream(
      responseID: "resp_subscription_final",
      text: "done",
      omitsTerminalOutput: true
    )
    let transport = TestOpenAIResponsesTransport(
      responses: [
        OpenAIResponsesTestFixture.response(data: firstResponse, contentType: nil),
        OpenAIResponsesTestFixture.response(data: secondResponse, contentType: nil),
      ]
    )
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesConfiguration(
        service: .chatGPTCodexSubscription,
        models: [OpenAIResponsesTestFixture.model()]
      ),
      authorizationProvider: StaticAuthorizationProvider(
        value: OpenAIResponsesAuthorization(
          bearerToken: "subscription-access-token",
          accountID: "account-test"
        )
      ),
      transport: transport
    )
    let tool = weatherTool()
    let user = Message(role: .user, content: [.text("Check the weather")])
    let call = ToolCall(
      id: ToolCallID(rawValue: "call_subscription_tool"),
      name: tool.name,
      arguments: ["city": .string("Zürich")]
    )

    let firstEvents = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request(messages: [user], tools: [tool])
    )
    #expect(firstEvents.contains(.toolCall(call)))
    #expect(firstEvents.last == .completed(.toolCalls))

    _ = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request(
        previousResponseID: "resp_subscription_tool",
        messages: [
          user,
          Message(role: .assistant, content: [.toolCall(call)]),
          Message(
            role: .tool,
            content: [
              .toolResult(
                ToolResult(
                  toolCallID: call.id,
                  status: .success,
                  output: .object(["temperature": .integer(18)])
                )
              )
            ]
          ),
        ],
        tools: [tool]
      )
    )

    let requests = await transport.requests()
    let secondRequest = try #require(requests.last)
    let body = try OpenAIResponsesTestFixture.jsonObject(from: secondRequest)
    let input = try #require(body["input"] as? [[String: Any]])
    #expect(
      input.map { $0["type"] as? String } == [
        "message", "reasoning", "function_call", "function_call_output",
      ]
    )
    #expect(input[1]["id"] == nil)
    #expect(input[2]["id"] == nil)
    #expect(input[2]["call_id"] as? String == call.id.rawValue)
  }

  @Test
  func chatGPTSubscriptionStillRequiresEncryptedReasoningWhenTerminalSnapshotIsOmitted()
    async throws
  {
    let responseData = try OpenAIResponsesTestFixture.toolStream(
      responseID: "resp_missing_encrypted_reasoning",
      callID: "call_missing_encrypted_reasoning",
      reasoningEncryptedContent: nil,
      omitsTerminalOutput: true
    )
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesConfiguration(
        service: .chatGPTCodexSubscription,
        models: [OpenAIResponsesTestFixture.model()]
      ),
      authorizationProvider: StaticAuthorizationProvider(
        value: OpenAIResponsesAuthorization(
          bearerToken: "subscription-access-token",
          accountID: "account-test"
        )
      ),
      transport: TestOpenAIResponsesTransport(
        responses: [OpenAIResponsesTestFixture.response(data: responseData, contentType: nil)]
      )
    )

    do {
      _ = try await OpenAIResponsesTestFixture.collect(
        provider: provider,
        request: OpenAIResponsesTestFixture.request(tools: [weatherTool()])
      )
      Issue.record("Expected missing encrypted reasoning to fail closed.")
    } catch let error as OpenAIResponsesProviderError {
      #expect(error == .encryptedReasoningUnavailable)
    }
  }

  @Test
  func apiKeyUsesPlatformEndpointWithoutSubscriptionHeaders() async throws {
    let responseData = try OpenAIResponsesTestFixture.textStream()
    let transport = TestOpenAIResponsesTransport(
      responses: [OpenAIResponsesTestFixture.response(data: responseData)]
    )
    let configuration = try OpenAIResponsesConfiguration(
      service: .platformAPI,
      models: [OpenAIResponsesTestFixture.model()]
    )
    let provider = OpenAIResponsesProvider(
      configuration: configuration,
      authorizationProvider: StaticAuthorizationProvider(
        value: OpenAIResponsesAuthorization(bearerToken: "platform-api-key")
      ),
      transport: transport
    )

    _ = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request()
    )

    let sent = try #require(await transport.requests().first)
    #expect(sent.url?.absoluteString == "https://api.openai.com/v1/responses")
    #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer platform-api-key")
    #expect(sent.value(forHTTPHeaderField: "ChatGPT-Account-ID") == nil)
    #expect(sent.value(forHTTPHeaderField: "originator") == nil)
    let body = try OpenAIResponsesTestFixture.jsonObject(from: sent)
    #expect(body["store"] as? Bool == true)
  }

  @Test
  func chatGPTSubscriptionUsesCodexEndpointAndHeadersWithoutServerStorage() async throws {
    let responseData = try OpenAIResponsesTestFixture.textStream()
    let transport = TestOpenAIResponsesTransport(
      responses: [OpenAIResponsesTestFixture.response(data: responseData)]
    )
    let configuration = try OpenAIResponsesConfiguration(
      service: .chatGPTCodexSubscription,
      models: [OpenAIResponsesTestFixture.model()]
    )
    let provider = OpenAIResponsesProvider(
      configuration: configuration,
      authorizationProvider: StaticAuthorizationProvider(
        value: OpenAIResponsesAuthorization(
          bearerToken: "subscription-access-token",
          accountID: "account-test"
        )
      ),
      transport: transport
    )

    _ = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request()
    )

    let sent = try #require(await transport.requests().first)
    #expect(sent.url?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
    #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer subscription-access-token")
    #expect(sent.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "account-test")
    #expect(sent.value(forHTTPHeaderField: "originator") == "hex")
    #expect(sent.value(forHTTPHeaderField: "User-Agent") == "Hex/1.0")

    let body = try OpenAIResponsesTestFixture.jsonObject(from: sent)
    #expect(body["store"] as? Bool == false)
    #expect(body["include"] as? [String] == ["reasoning.encrypted_content"])
    #expect(body["previous_response_id"] == nil)
  }

  @Test
  func platformAPIRejectsSubscriptionAuthorizationBeforeNetworkUse() async throws {
    let transport = TestOpenAIResponsesTransport(responses: [])
    let configuration = try OpenAIResponsesConfiguration(
      service: .platformAPI,
      models: [OpenAIResponsesTestFixture.model()]
    )
    let provider = OpenAIResponsesProvider(
      configuration: configuration,
      authorizationProvider: StaticAuthorizationProvider(
        value: OpenAIResponsesAuthorization(
          bearerToken: "subscription-access-token",
          accountID: "account-test"
        )
      ),
      transport: transport
    )

    do {
      _ = try await provider.stream(OpenAIResponsesTestFixture.request())
      Issue.record("Expected subscription authorization to be rejected on the API-key route.")
    } catch let error as OpenAIResponsesProviderError {
      #expect(error == .credentialUnavailable)
    }

    #expect(await transport.requests().isEmpty)
  }

  @Test
  func chatGPTSubscriptionRequiresAnAccountIDBeforeNetworkUse() async throws {
    let transport = TestOpenAIResponsesTransport(responses: [])
    let configuration = try OpenAIResponsesConfiguration(
      service: .chatGPTCodexSubscription,
      models: [OpenAIResponsesTestFixture.model()]
    )
    let provider = OpenAIResponsesProvider(
      configuration: configuration,
      authorizationProvider: StaticAuthorizationProvider(
        value: OpenAIResponsesAuthorization(bearerToken: "subscription-access-token")
      ),
      transport: transport
    )

    do {
      _ = try await provider.stream(OpenAIResponsesTestFixture.request())
      Issue.record("Expected ChatGPT authorization without an account ID to be rejected.")
    } catch let error as OpenAIResponsesProviderError {
      #expect(error == .credentialUnavailable)
    }

    #expect(await transport.requests().isEmpty)
  }

  private struct StaticAuthorizationProvider: OpenAIResponsesAuthorizationProvider {
    let value: OpenAIResponsesAuthorization

    func authorization() async throws -> OpenAIResponsesAuthorization {
      value
    }
  }

  private func weatherTool() -> ToolDefinition {
    ToolDefinition(
      name: "lookup_weather",
      description: "Look up weather for a city.",
      inputSchema: ["type": .string("object")]
    )
  }
}
