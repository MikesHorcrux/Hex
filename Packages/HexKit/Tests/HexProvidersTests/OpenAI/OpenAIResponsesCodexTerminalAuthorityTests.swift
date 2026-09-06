import Foundation
import HexCore
import Testing

@testable import HexProviders

@Suite("Codex terminal content authority")
struct OpenAIResponsesCodexTerminalAuthorityTests {
  @Test(arguments: ["missing", "null", "scalar", "contradictory"])
  func terminalSnapshotCannotReplaceValidatedDoneItems(shape: String) async throws {
    let data = try transform(
      OpenAIResponsesTestFixture.textStream(text: "trusted output")
    ) { event in
      guard event["type"] as? String == "response.completed" else { return event }
      var event = event
      var response = try #require(event["response"] as? [String: Any])
      switch shape {
      case "missing":
        response.removeValue(forKey: "output")
      case "null":
        response["output"] = NSNull()
      case "scalar":
        response["output"] = "not a content authority"
      default:
        response["output"] = [
          [
            "id": "msg_terminal_only", "type": "message", "role": "assistant",
            "status": "completed",
            "content": [
              ["type": "output_text", "text": "untrusted replacement", "annotations": []]
            ],
          ],
          [
            "id": "fc_terminal_only", "type": "function_call", "status": "completed",
            "call_id": "call_terminal_only", "name": "lookup_weather", "arguments": "{}",
          ],
          [
            "id": "rs_terminal_only", "type": "reasoning", "status": "completed",
            "summary": [["type": "summary_text", "text": "terminal-only reasoning"]],
            "encrypted_content": "terminal-only-state",
          ],
        ]
      }
      event["response"] = response
      return event
    }
    let events = try await OpenAIResponsesTestFixture.collect(
      provider: makeProvider(data: data),
      request: OpenAIResponsesTestFixture.request(tools: [weatherTool()])
    )

    #expect(events.contains(.textDelta("trusted output")))
    #expect(!events.contains(.textDelta("untrusted replacement")))
    #expect(!events.contains(.reasoningSummaryDelta("terminal-only reasoning")))
    #expect(toolCalls(in: events).isEmpty)
    #expect(events.last == .completed(.stop))
  }

  @Test
  func acceptsLargeTerminalMetadataWithoutTreatingItAsOutput() async throws {
    let data = try transform(OpenAIResponsesTestFixture.textStream(text: "online")) { event in
      guard event["type"] as? String == "response.completed" else { return event }
      var event = event
      var response = try #require(event["response"] as? [String: Any])
      response["metadata"] = ["opaque_provider_metadata": String(repeating: "x", count: 96 * 1_024)]
      response.removeValue(forKey: "output")
      event["response"] = response
      return event
    }
    let events = try await OpenAIResponsesTestFixture.collect(
      provider: makeProvider(data: data),
      request: OpenAIResponsesTestFixture.request()
    )

    #expect(events.contains(.textDelta("online")))
    #expect(events.last == .completed(.stop))
  }

  @Test
  func terminalSnapshotCannotCompleteAnUnfinishedStreamedTool() async throws {
    let data = try transform(
      OpenAIResponsesTestFixture.toolStream(
        responseID: "resp_unfinished", callID: "call_unfinished", includeReasoning: false
      )
    ) { event in
      // Keep arguments.done and the complete terminal snapshot. Only output_item.done is absent.
      // The transformer renumbers remaining events, so rejection cannot come from a sequence gap.
      event["type"] as? String == "response.output_item.done" ? nil : event
    }
    let events = try await expectMalformedWithoutToolEvents(data: data)
    #expect(!events.contains(.completed(.toolCalls)))
  }

  @Test(arguments: [OpenAIResponsesService.platformAPI, .chatGPTCodexSubscription])
  func optionalReasoningAndFunctionStatusesMayBeAbsent(service: OpenAIResponsesService) async throws
  {
    let data = try transform(
      OpenAIResponsesTestFixture.toolStream(
        responseID: "resp_statusless", callID: "call_statusless")
    ) { event in
      var event = event
      if var item = event["item"] as? [String: Any] {
        item.removeValue(forKey: "status")
        event["item"] = item
      }
      if var response = event["response"] as? [String: Any],
        let output = response["output"] as? [[String: Any]]
      {
        response["output"] = output.map { item in
          var item = item
          item.removeValue(forKey: "status")
          return item
        }
        event["response"] = response
      }
      return event
    }
    let events = try await OpenAIResponsesTestFixture.collect(
      provider: makeProvider(data: data, service: service),
      request: OpenAIResponsesTestFixture.request(tools: [weatherTool()])
    )

    #expect(toolCalls(in: events).map(\.id.rawValue) == ["call_statusless"])
    #expect(events.last == .completed(.toolCalls))
  }

  @Test(arguments: [OpenAIResponsesService.platformAPI, .chatGPTCodexSubscription])
  func explicitlyIncompleteFunctionIsStillRejected(service: OpenAIResponsesService) async throws {
    let data = try transform(
      OpenAIResponsesTestFixture.toolStream(
        responseID: "resp_incomplete", callID: "call_incomplete", includeReasoning: false
      )
    ) { event in
      guard event["type"] as? String == "response.output_item.done" else { return event }
      var event = event
      var item = try #require(event["item"] as? [String: Any])
      item["status"] = "incomplete"
      event["item"] = item
      return event
    }
    _ = try await expectMalformedWithoutToolEvents(data: data, service: service)
  }

  @Test
  func codexArgumentsDoneMayOmitNameAlreadyBoundToTheStreamedItem() async throws {
    let data = try argumentsDoneWithoutNameStream()
    let events = try await OpenAIResponsesTestFixture.collect(
      provider: makeProvider(data: data),
      request: OpenAIResponsesTestFixture.request(tools: [weatherTool()])
    )
    #expect(
      toolCalls(in: events) == [
        ToolCall(
          id: ToolCallID(rawValue: "call_nameless_done"),
          name: "lookup_weather",
          arguments: ["city": .string("Zürich")]
        )
      ]
    )
    #expect(events.last == .completed(.toolCalls))
  }

  @Test
  func platformArgumentsDoneStillRequiresName() async throws {
    _ = try await expectMalformedWithoutToolEvents(
      data: argumentsDoneWithoutNameStream(), service: .platformAPI
    )
  }

  @Test(arguments: [OpenAIResponsesService.platformAPI, .chatGPTCodexSubscription])
  func conflictingArgumentsDoneNameIsRejected(service: OpenAIResponsesService) async throws {
    let data = try transform(
      OpenAIResponsesTestFixture.toolStream(
        responseID: "resp_conflicting_done", callID: "call_conflicting_done",
        includeReasoning: false
      )
    ) { event in
      guard event["type"] as? String == "response.function_call_arguments.done" else {
        return event
      }
      var event = event
      event["name"] = "different_tool"
      return event
    }
    _ = try await expectMalformedWithoutToolEvents(data: data, service: service)
  }

  @Test(arguments: [OpenAIResponsesService.platformAPI, .chatGPTCodexSubscription])
  func conflictingCompletedItemNameIsRejected(service: OpenAIResponsesService) async throws {
    let data = try transform(
      OpenAIResponsesTestFixture.toolStream(
        responseID: "resp_conflicting_item", callID: "call_conflicting_item",
        includeReasoning: false
      )
    ) { event in
      guard event["type"] as? String == "response.output_item.done" else { return event }
      var event = event
      var item = try #require(event["item"] as? [String: Any])
      item["name"] = "different_tool"
      event["item"] = item
      return event
    }
    _ = try await expectMalformedWithoutToolEvents(data: data, service: service)
  }

  @Test(
    arguments: [OpenAIResponsesService.platformAPI, .chatGPTCodexSubscription],
    ["null", "boolean", "number", "object", "array"]
  )
  func presentNonStringArgumentsDoneNameIsRejected(
    service: OpenAIResponsesService,
    shape: String
  ) async throws {
    let data = try transform(
      OpenAIResponsesTestFixture.toolStream(
        responseID: "resp_wrong_name_type", callID: "call_wrong_name_type", includeReasoning: false
      )
    ) { event in
      guard event["type"] as? String == "response.function_call_arguments.done" else {
        return event
      }
      var event = event
      switch shape {
      case "null": event["name"] = NSNull()
      case "boolean": event["name"] = false
      case "number": event["name"] = 12
      case "object": event["name"] = ["value": "lookup_weather"]
      default: event["name"] = ["lookup_weather"]
      }
      return event
    }
    _ = try await expectMalformedWithoutToolEvents(data: data, service: service)
  }

  @Test
  func namelessArgumentsDoneDoesNotEmitTheToolBeforeTerminalValidation() throws {
    let configuration = try OpenAIResponsesConfiguration(
      service: .chatGPTCodexSubscription, models: [OpenAIResponsesTestFixture.model()]
    )
    var parser = ServerSentEventParser(configuration: configuration)
    var processor = OpenAIResponsesStreamProcessor(
      configuration: configuration,
      tools: [weatherTool()],
      toolChoice: .automatic,
      allowsParallelToolCalls: false
    )
    var terminalSeen = false
    for serverEvent in try parser.feed(argumentsDoneWithoutNameStream()) {
      let processed = try processor.process(serverEvent)
      if processed.terminalResult != nil {
        #expect(!terminalSeen)
        terminalSeen = true
        #expect(toolCalls(in: processed.events).count == 1)
      } else {
        #expect(toolCalls(in: processed.events).isEmpty)
      }
    }
    #expect(terminalSeen)
    try processor.finish()
  }

  private func argumentsDoneWithoutNameStream() throws -> Data {
    try transform(
      OpenAIResponsesTestFixture.toolStream(
        responseID: "resp_nameless_done", callID: "call_nameless_done", includeReasoning: false
      )
    ) { event in
      guard event["type"] as? String == "response.function_call_arguments.done" else {
        return event
      }
      var event = event
      event.removeValue(forKey: "name")
      return event
    }
  }

  private func expectMalformedWithoutToolEvents(
    data: Data,
    service: OpenAIResponsesService = .chatGPTCodexSubscription
  ) async throws -> [InferenceStreamEvent] {
    let provider = try makeProvider(data: data, service: service)
    let stream = try await provider.stream(
      OpenAIResponsesTestFixture.request(tools: [weatherTool()])
    )
    let events = try await stream.consume { cursor in
      var events: [InferenceStreamEvent] = []
      do {
        while let event = try await cursor.next() { events.append(event) }
        Issue.record("Expected an unfinished tool to fail before execution.")
      } catch let error as OpenAIResponsesProviderError {
        #expect(error == .malformedStream)
      }
      return events
    }
    #expect(toolCalls(in: events).isEmpty)
    return events
  }

  private func makeProvider(
    data: Data,
    service: OpenAIResponsesService = .chatGPTCodexSubscription
  ) throws -> OpenAIResponsesProvider {
    OpenAIResponsesProvider(
      configuration: try OpenAIResponsesConfiguration(
        service: service, models: [OpenAIResponsesTestFixture.model()]
      ),
      authorizationProvider: StaticAuthorizationProvider(
        value: OpenAIResponsesAuthorization(
          bearerToken: "synthetic-access-token",
          accountID: service == .chatGPTCodexSubscription ? "synthetic-account" : nil
        )
      ),
      transport: TestOpenAIResponsesTransport(
        responses: [OpenAIResponsesTestFixture.response(data: data)]
      )
    )
  }

  private func weatherTool() -> ToolDefinition {
    ToolDefinition(
      name: "lookup_weather",
      description: "Look up weather for a city.",
      inputSchema: ["type": .string("object")]
    )
  }

  private func toolCalls(in events: [InferenceStreamEvent]) -> [ToolCall] {
    events.compactMap { event in
      guard case .toolCall(let call) = event else { return nil }
      return call
    }
  }

  private func transform(
    _ data: Data,
    event transformEvent: ([String: Any]) throws -> [String: Any]?
  ) throws -> Data {
    let text = try #require(String(data: data, encoding: .utf8))
    var transformed = Data()
    var sequence = 0
    for line in text.split(separator: "\n") where line.hasPrefix("data: ") {
      let payload = String(line.dropFirst(6))
      if payload == "[DONE]" {
        transformed.append(Data("data: [DONE]\n\n".utf8))
        continue
      }
      let original = try #require(
        JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
      )
      guard var event = try transformEvent(original) else { continue }
      event["sequence_number"] = sequence
      sequence += 1
      try OpenAIResponsesTestFixture.appendEvent(event, to: &transformed)
    }
    return transformed
  }

  private struct StaticAuthorizationProvider: OpenAIResponsesAuthorizationProvider {
    let value: OpenAIResponsesAuthorization

    func authorization() async throws -> OpenAIResponsesAuthorization { value }
  }
}
