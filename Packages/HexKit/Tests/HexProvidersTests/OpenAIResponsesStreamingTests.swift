import Foundation
import HexCore
import Testing

@testable import HexProviders

@Suite("OpenAI Responses streaming")
struct OpenAIResponsesStreamingTests {
  @Test
  func mapsReasoningCompleteToolCallUsageAndCompletion() async throws {
    let streamData = try OpenAIResponsesTestFixture.toolStream(
      responseID: "resp_tool",
      callID: "call_weather"
    )
    let transport = TestOpenAIResponsesTransport(
      responses: [OpenAIResponsesTestFixture.response(data: streamData)]
    )
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-stream"),
      transport: transport
    )

    let events = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request(tools: [weatherTool()])
    )

    #expect(
      events == [
        .started(providerResponseID: "resp_tool"),
        .reasoningSummaryDelta("Checking weather"),
        .toolCall(
          ToolCall(
            id: ToolCallID(rawValue: "call_weather"),
            name: "lookup_weather",
            arguments: ["city": .string("Zürich")]
          )
        ),
        .usage(
          InferenceUsage(
            inputTokens: 20,
            outputTokens: 8,
            cachedInputTokens: 4,
            reasoningTokens: 5
          )
        ),
        .completed(.toolCalls),
      ])
  }

  @Test
  func parsesFragmentedMultibyteCRLFCommentsAndMultipleDataLines() async throws {
    let expectedText = "Grüße 👋"
    let streamData = try OpenAIResponsesTestFixture.textStream(
      responseID: "resp_unicode",
      text: expectedText,
      lineEnding: "\r\n",
      decorateDelta: true
    )
    let offsets = Array(stride(from: 1, to: streamData.count, by: 7))
    let transport = TestOpenAIResponsesTransport(
      responses: [
        OpenAIResponsesTestFixture.response(data: streamData, splitAt: offsets)
      ]
    )
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-unicode"),
      transport: transport
    )

    let events = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request()
    )

    #expect(
      events == [
        .started(providerResponseID: "resp_unicode"),
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
      ])
  }

  @Test
  func validatesTextAnnotationsWithoutLeakingProviderSpecificEvents() async throws {
    let streamData = try OpenAIResponsesTestFixture.textStream(
      responseID: "resp_annotation",
      text: "Source",
      annotation: [
        "type": "url_citation",
        "start_index": 0,
        "end_index": 6,
        "title": "Official source",
        "url": "https://developers.openai.com/",
      ]
    )
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-annotation"),
      transport: TestOpenAIResponsesTransport(
        responses: [OpenAIResponsesTestFixture.response(data: streamData)]
      )
    )

    let events = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request()
    )
    #expect(events.first == .started(providerResponseID: "resp_annotation"))
    #expect(events.filter { $0 == .textDelta("Source") }.count == 1)
    #expect(events.last == .completed(.stop))
  }

  @Test
  func mapsValidatedRefusalAsFilteredText() async throws {
    let streamData = try OpenAIResponsesTestFixture.textStream(
      responseID: "resp_refusal",
      text: "I cannot help with that.",
      refusal: true
    )
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-refusal"),
      transport: TestOpenAIResponsesTransport(
        responses: [OpenAIResponsesTestFixture.response(data: streamData)]
      )
    )

    let events = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request()
    )
    #expect(events.contains(.textDelta("I cannot help with that.")))
    #expect(events.last == .completed(.contentFilter))
  }

  @Test
  func mapsIncompleteTokenLimitToLengthStop() async throws {
    let streamData = try OpenAIResponsesTestFixture.textStream(
      responseID: "resp_incomplete",
      text: "Partial",
      terminalStatus: "incomplete",
      incompleteReason: "max_output_tokens"
    )
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-incomplete"),
      transport: TestOpenAIResponsesTransport(
        responses: [OpenAIResponsesTestFixture.response(data: streamData)]
      )
    )

    let events = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request()
    )
    #expect(events.contains(.textDelta("Partial")))
    #expect(events.last == .completed(.length))
  }

  @Test
  func acceptsIntegralTemperatureWithCanonicalJSONEncoding() async throws {
    let streamData = try OpenAIResponsesTestFixture.textStream(responseID: "resp_temperature")
    let transport = TestOpenAIResponsesTransport(
      responses: [OpenAIResponsesTestFixture.response(data: streamData)]
    )
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-temperature"),
      transport: transport
    )
    let request = OpenAIResponsesTestFixture.request(
      options: InferenceOptions(temperature: 1)
    )

    _ = try await OpenAIResponsesTestFixture.collect(provider: provider, request: request)
    let requests = await transport.requests()
    let sent = try #require(requests.first)
    let body = try OpenAIResponsesTestFixture.jsonObject(from: sent)
    #expect(body["temperature"] as? Int == 1)
  }

  @Test
  func serverManagedResponsesIgnoreUnrelatedLocalCacheLimit() async throws {
    let streamData = try OpenAIResponsesTestFixture.textStream(responseID: "resp_server_limit")
    let transport = TestOpenAIResponsesTransport(
      responses: [OpenAIResponsesTestFixture.response(data: streamData)]
    )
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(
        maximumLocalStateBytes: 1,
        maximumLocalCacheBytes: 1
      ),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-server-limit"),
      transport: transport
    )

    let events = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request()
    )
    #expect(events.last == .completed(.stop))
  }

  private func weatherTool() -> ToolDefinition {
    ToolDefinition(
      name: "lookup_weather",
      description: "Look up weather for a city.",
      inputSchema: [
        "type": .string("object"),
        "properties": .object(["city": .object(["type": .string("string")])]),
        "required": .array([.string("city")]),
        "additionalProperties": .boolean(false),
      ]
    )
  }
}
