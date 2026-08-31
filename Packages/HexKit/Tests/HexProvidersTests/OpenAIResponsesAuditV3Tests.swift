import Foundation
import HexCore
import Testing

@testable import HexProviders

@Suite("OpenAI Responses hostile audit v3")
struct OpenAIResponsesAuditV3Tests {
  @Test
  func rejectsOutputAndSuccessfulTerminalWhileResponseIsStillQueued() async throws {
    for mode in modes {
      let outputResponseID = "resp_queued_output_\(mode.rawValue)"
      let ordinary = try OpenAIResponsesTestFixture.textStream(responseID: outputResponseID)
      let ordinaryText = try #require(String(data: ordinary, encoding: .utf8))
      let queuedOutput = Data(
        ordinaryText.replacingOccurrences(
          of: "\"status\":\"in_progress\"},\"sequence_number\":0",
          with: "\"status\":\"queued\"},\"sequence_number\":0"
        ).utf8
      )
      #expect(await outcome(queuedOutput, mode: mode) == .provider(.malformedStream))

      let terminalResponseID = "resp_queued_terminal_\(mode.rawValue)"
      var queuedTerminal = Data()
      try OpenAIResponsesTestFixture.appendEvent(
        [
          "type": "response.created",
          "sequence_number": 0,
          "response": ["id": terminalResponseID, "status": "queued"],
        ],
        to: &queuedTerminal
      )
      try OpenAIResponsesTestFixture.appendEvent(
        [
          "type": "response.completed",
          "sequence_number": 1,
          "response": ["id": terminalResponseID, "status": "completed", "output": []],
        ],
        to: &queuedTerminal
      )
      #expect(await outcome(queuedTerminal, mode: mode) == .provider(.malformedStream))

      let incompleteResponseID = "resp_queued_incomplete_\(mode.rawValue)"
      var queuedIncomplete = Data()
      try OpenAIResponsesTestFixture.appendEvent(
        [
          "type": "response.created",
          "sequence_number": 0,
          "response": ["id": incompleteResponseID, "status": "queued"],
        ],
        to: &queuedIncomplete
      )
      try OpenAIResponsesTestFixture.appendEvent(
        [
          "type": "response.incomplete",
          "sequence_number": 1,
          "response": [
            "id": incompleteResponseID,
            "status": "incomplete",
            "output": [],
            "incomplete_details": ["reason": "max_output_tokens"],
          ],
        ],
        to: &queuedIncomplete
      )
      #expect(await outcome(queuedIncomplete, mode: mode) == .provider(.malformedStream))
    }
  }

  @Test
  func permitsExplicitFailedAndCancelledTerminalsWhileQueued() async throws {
    for mode in modes {
      for terminal in [("response.failed", "failed"), ("response.cancelled", "cancelled")] {
        let responseID = "resp_queued_\(terminal.1)_\(mode.rawValue)"
        var data = Data()
        try OpenAIResponsesTestFixture.appendEvent(
          [
            "type": "response.created",
            "sequence_number": 0,
            "response": ["id": responseID, "status": "queued"],
          ],
          to: &data
        )
        try OpenAIResponsesTestFixture.appendEvent(
          [
            "type": terminal.0,
            "sequence_number": 1,
            "response": ["id": responseID, "status": terminal.1],
          ],
          to: &data
        )
        let result = await collect(data, mode: mode)
        #expect(result.error == .responseFailed)
        #expect(!result.events.contains(where: isCompletion))
        if let provider = result.provider {
          #expect(await provider.serverStates[responseID] == nil)
          #expect(await provider.localStates[responseID] == nil)
        } else {
          Issue.record("Expected a provider for queued terminal validation.")
        }
      }
    }
  }

  @Test
  func rejectsDuplicateSecurityCriticalJSONMembers() async throws {
    for mode in modes {
      let responseID = "resp_duplicate_member_\(mode.rawValue)"
      let data = Data(
        """
        data: {"type":"response.created","sequence_number":0,"response":{"id":"ignored","id":"\(responseID)","status":"in_progress"}}

        data: {"type":"response.completed","sequence_number":1,"response":{"id":"ignored","id":"\(responseID)","status":"completed","output":[]}}

        """.utf8
      )
      #expect(await outcome(data, mode: mode) == .provider(.malformedStream))

      let escapedMember = Data(
        """
        data: {"type":"response.created","sequence_number":0,"response":{"id":"ignored","\\u0069d":"\(responseID)","status":"in_progress"}}

        data: {"type":"response.completed","sequence_number":1,"response":{"id":"\(responseID)","status":"completed","output":[]}}

        """.utf8
      )
      #expect(await outcome(escapedMember, mode: mode) == .provider(.malformedStream))

      let duplicateArguments = try OpenAIResponsesTestFixture.toolStream(
        responseID: "resp_duplicate_args_\(mode.rawValue)",
        callID: "call_duplicate_args_\(mode.rawValue)",
        arguments: "{\"city\":\"safe\",\"city\":\"danger\"}",
        includeReasoning: false
      )
      #expect(
        await outcome(duplicateArguments, mode: mode, tools: [weatherTool])
          == .provider(.malformedStream)
      )

      let escapedDuplicateArguments = try OpenAIResponsesTestFixture.toolStream(
        responseID: "resp_escaped_duplicate_args_\(mode.rawValue)",
        callID: "call_escaped_duplicate_args_\(mode.rawValue)",
        arguments: "{\"city\":\"safe\",\"\\u0063ity\":\"danger\"}",
        includeReasoning: false
      )
      #expect(
        await outcome(escapedDuplicateArguments, mode: mode, tools: [weatherTool])
          == .provider(.malformedStream)
      )
    }
  }

  @Test
  func neverPublishesToolCallsWithANonToolTerminalReason() async throws {
    for mode in modes {
      let responseID = "resp_incomplete_tool_\(mode.rawValue)"
      let completed = try OpenAIResponsesTestFixture.toolStream(
        responseID: responseID,
        callID: "call_incomplete_\(mode.rawValue)",
        includeReasoning: false
      )
      let incomplete = try replacingTerminal(
        in: completed,
        type: "response.incomplete",
        status: "incomplete",
        incompleteReason: "max_output_tokens"
      )
      let result = await collect(incomplete, mode: mode, tools: [weatherTool])
      #expect(result.error == .malformedStream)
      #expect(!result.events.contains(where: isToolCall))
      #expect(!result.events.contains(where: isCompletion))
      if let provider = result.provider {
        #expect(await provider.serverStates[responseID] == nil)
        #expect(await provider.localStates[responseID] == nil)
      } else {
        Issue.record("Expected a provider for incomplete tool-call validation.")
      }
    }
  }

  @Test
  func rejectsEmptySuccessfulResponseThatCannotFormAnAssistantTurn() async throws {
    for mode in modes {
      let responseID = "resp_empty_\(mode.rawValue)"
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
          "type": "response.completed",
          "sequence_number": 1,
          "response": ["id": responseID, "status": "completed", "output": []],
        ],
        to: &data
      )
      #expect(await outcome(data, mode: mode) == .provider(.malformedStream))

      #expect(
        await outcome(
          try emptyCompletedMessageStream(
            responseID: "resp_empty_message_\(mode.rawValue)"
          ),
          mode: mode
        ) == .provider(.malformedStream)
      )

      #expect(
        await outcome(
          try reasoningOnlyCompletedStream(
            responseID: "resp_reasoning_only_\(mode.rawValue)"
          ),
          mode: mode
        ) == .provider(.malformedStream)
      )
    }
  }

  @Test
  func enforcesToolChoiceAndDeclaredToolNamesAtProviderBoundary() async throws {
    for mode in modes {
      let noneData = try OpenAIResponsesTestFixture.toolStream(
        responseID: "resp_none_tool_\(mode.rawValue)",
        callID: "call_none_\(mode.rawValue)",
        includeReasoning: false
      )
      #expect(
        await outcome(
          noneData,
          mode: mode,
          tools: [weatherTool],
          toolChoice: .none
        ) == .provider(.malformedStream)
      )

      let foreignData = try OpenAIResponsesTestFixture.toolStream(
        responseID: "resp_foreign_tool_\(mode.rawValue)",
        callID: "call_foreign_\(mode.rawValue)",
        toolName: "delete_everything",
        includeReasoning: false
      )
      #expect(
        await outcome(
          foreignData,
          mode: mode,
          tools: [weatherTool],
          toolChoice: .automatic
        ) == .provider(.malformedStream)
      )

      #expect(
        await outcome(
          foreignData,
          mode: mode,
          tools: [weatherTool],
          toolChoice: .named("lookup_weather")
        ) == .provider(.malformedStream)
      )

      let undeclaredData = try OpenAIResponsesTestFixture.toolStream(
        responseID: "resp_undeclared_tool_\(mode.rawValue)",
        callID: "call_undeclared_tool_\(mode.rawValue)",
        includeReasoning: false
      )
      #expect(
        await outcome(
          undeclaredData,
          mode: mode,
          tools: [],
          toolChoice: .automatic
        ) == .provider(.malformedStream)
      )

      let namedData = try OpenAIResponsesTestFixture.toolStream(
        responseID: "resp_named_tool_\(mode.rawValue)",
        callID: "call_named_tool_\(mode.rawValue)",
        includeReasoning: true
      )
      #expect(
        await outcome(
          namedData,
          mode: mode,
          tools: [weatherTool],
          toolChoice: .named("lookup_weather")
        ) == .success
      )

      let requiredData = try OpenAIResponsesTestFixture.toolStream(
        responseID: "resp_required_tool_\(mode.rawValue)",
        callID: "call_required_tool_\(mode.rawValue)",
        includeReasoning: true
      )
      #expect(
        await outcome(
          requiredData,
          mode: mode,
          tools: [weatherTool],
          toolChoice: .required
        ) == .success
      )
    }
  }

  @Test
  func rejectsInterleavedOutputItemsAndPublishedParts() async throws {
    for mode in modes {
      let streams = try [
        interleavedMessageStream(responseID: "resp_interleaved_\(mode.rawValue)"),
        interleavedMessagePartPrefix(
          responseID: "resp_interleaved_parts_\(mode.rawValue)"
        ),
        interleavedReasoningPartPrefix(
          responseID: "resp_interleaved_reasoning_\(mode.rawValue)"
        ),
      ]
      for stream in streams {
        let result = await collect(stream, mode: mode)
        #expect(result.error == .malformedStream)
        #expect(!result.events.contains(where: isCompletion))
      }
    }
  }

  private let modes: [OpenAIResponsesPrivacyMode] = [
    .serverManagedContinuation,
    .localEphemeralReplay,
  ]

  private var weatherTool: ToolDefinition {
    ToolDefinition(
      name: "lookup_weather",
      description: "Look up weather.",
      inputSchema: ["type": .string("object")]
    )
  }

  private func outcome(
    _ data: Data,
    mode: OpenAIResponsesPrivacyMode,
    tools: [ToolDefinition] = [],
    toolChoice: ToolChoice = .automatic
  ) async -> AuditOutcome {
    let result = await collect(data, mode: mode, tools: tools, toolChoice: toolChoice)
    if let error = result.error {
      return .provider(error)
    }
    return .success
  }

  private func collect(
    _ data: Data,
    mode: OpenAIResponsesPrivacyMode,
    tools: [ToolDefinition] = [],
    toolChoice: ToolChoice = .automatic
  ) async -> AuditResult {
    var provider: OpenAIResponsesProvider?
    var events: [InferenceStreamEvent] = []
    do {
      let configuredProvider = OpenAIResponsesProvider(
        configuration: try OpenAIResponsesTestFixture.configuration(privacyMode: mode),
        credentialProvider: TestOpenAICredentialProvider(key: "sk-hostile-audit"),
        transport: TestOpenAIResponsesTransport(
          responses: [OpenAIResponsesTestFixture.response(data: data)]
        )
      )
      provider = configuredProvider
      let stream = try await configuredProvider.stream(
        OpenAIResponsesTestFixture.request(tools: tools, toolChoice: toolChoice)
      )
      for try await event in stream {
        events.append(event)
      }
      return AuditResult(events: events, error: nil, provider: configuredProvider)
    } catch let error as OpenAIResponsesProviderError {
      return AuditResult(events: events, error: error, provider: provider)
    } catch {
      Issue.record("Unexpected error type: \(error)")
      return AuditResult(events: events, error: nil, provider: provider)
    }
  }

  private func emptyCompletedMessageStream(responseID: String) throws -> Data {
    let addedItem: [String: Any] = [
      "id": "msg_empty",
      "type": "message",
      "status": "in_progress",
      "role": "assistant",
      "content": [],
    ]
    let completedItem: [String: Any] = [
      "id": "msg_empty",
      "type": "message",
      "status": "completed",
      "role": "assistant",
      "content": [],
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
        "item": addedItem,
      ],
      to: &data
    )
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.output_item.done",
        "sequence_number": 2,
        "output_index": 0,
        "item": completedItem,
      ],
      to: &data
    )
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.completed",
        "sequence_number": 3,
        "response": [
          "id": responseID,
          "status": "completed",
          "output": [completedItem],
        ],
      ],
      to: &data
    )
    return data
  }

  private func reasoningOnlyCompletedStream(responseID: String) throws -> Data {
    let addedItem: [String: Any] = [
      "id": "reasoning_only",
      "type": "reasoning",
      "summary": [],
    ]
    let completedItem: [String: Any] = [
      "id": "reasoning_only",
      "type": "reasoning",
      "status": "completed",
      "summary": [],
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
        "item": addedItem,
      ],
      to: &data
    )
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.output_item.done",
        "sequence_number": 2,
        "output_index": 0,
        "item": completedItem,
      ],
      to: &data
    )
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.completed",
        "sequence_number": 3,
        "response": [
          "id": responseID,
          "status": "completed",
          "output": [completedItem],
        ],
      ],
      to: &data
    )
    return data
  }

  private func replacingTerminal(
    in data: Data,
    type: String,
    status: String,
    incompleteReason: String
  ) throws -> Data {
    let source = try #require(String(data: data, encoding: .utf8))
    var rebuilt = Data()
    for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
      guard line.hasPrefix("data: {") else {
        rebuilt.append(Data("\(line)\n".utf8))
        continue
      }
      let payload = Data(line.dropFirst("data: ".count).utf8)
      guard
        var object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
        object["type"] as? String == "response.completed",
        var response = object["response"] as? [String: Any]
      else {
        rebuilt.append(Data("\(line)\n".utf8))
        continue
      }
      object["type"] = type
      response["status"] = status
      response["incomplete_details"] = ["reason": incompleteReason]
      object["response"] = response
      let mutated = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      rebuilt.append(Data("data: ".utf8))
      rebuilt.append(mutated)
      rebuilt.append(Data("\n".utf8))
    }
    return rebuilt
  }

  private func interleavedMessageStream(responseID: String) throws -> Data {
    let firstAdded: [String: Any] = [
      "id": "msg_first", "type": "message", "status": "in_progress",
      "role": "assistant", "content": [],
    ]
    let secondAdded: [String: Any] = [
      "id": "msg_second", "type": "message", "status": "in_progress",
      "role": "assistant", "content": [],
    ]
    let firstDone: [String: Any] = [
      "id": "msg_first", "type": "message", "status": "completed",
      "role": "assistant",
      "content": [["type": "output_text", "text": "AC", "annotations": []]],
    ]
    let secondDone: [String: Any] = [
      "id": "msg_second", "type": "message", "status": "completed",
      "role": "assistant",
      "content": [["type": "output_text", "text": "B", "annotations": []]],
    ]
    var data = Data()
    var sequence = 0
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.created", "sequence_number": sequence,
        "response": ["id": responseID, "status": "in_progress"],
      ],
      to: &data
    )
    sequence += 1
    try appendMessageAdded(firstAdded, outputIndex: 0, sequence: &sequence, to: &data)
    try appendTextDelta("A", itemID: "msg_first", outputIndex: 0, sequence: &sequence, to: &data)
    try appendMessageAdded(secondAdded, outputIndex: 1, sequence: &sequence, to: &data)
    try appendTextDelta("B", itemID: "msg_second", outputIndex: 1, sequence: &sequence, to: &data)
    try appendTextDelta("C", itemID: "msg_first", outputIndex: 0, sequence: &sequence, to: &data)
    try appendMessageDone(
      itemID: "msg_first", outputIndex: 0, text: "AC", item: firstDone,
      sequence: &sequence, to: &data
    )
    try appendMessageDone(
      itemID: "msg_second", outputIndex: 1, text: "B", item: secondDone,
      sequence: &sequence, to: &data
    )
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.completed", "sequence_number": sequence,
        "response": ["id": responseID, "status": "completed", "output": [firstDone, secondDone]],
      ],
      to: &data
    )
    return data
  }

  private func interleavedMessagePartPrefix(responseID: String) throws -> Data {
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
        "item": [
          "id": "msg_parts",
          "type": "message",
          "status": "in_progress",
          "role": "assistant",
          "content": [],
        ],
      ],
      to: &data
    )
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.content_part.added",
        "sequence_number": 2,
        "item_id": "msg_parts",
        "output_index": 0,
        "content_index": 0,
        "part": ["type": "output_text", "text": "", "annotations": []],
      ],
      to: &data
    )
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.output_text.delta",
        "sequence_number": 3,
        "item_id": "msg_parts",
        "output_index": 0,
        "content_index": 0,
        "delta": "A",
      ],
      to: &data
    )
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.content_part.added",
        "sequence_number": 4,
        "item_id": "msg_parts",
        "output_index": 0,
        "content_index": 1,
        "part": ["type": "output_text", "text": "", "annotations": []],
      ],
      to: &data
    )
    return data
  }

  private func interleavedReasoningPartPrefix(responseID: String) throws -> Data {
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
        "item": [
          "id": "reasoning_parts",
          "type": "reasoning",
          "summary": [],
        ],
      ],
      to: &data
    )
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.reasoning_summary_part.added",
        "sequence_number": 2,
        "item_id": "reasoning_parts",
        "output_index": 0,
        "summary_index": 0,
        "part": ["type": "summary_text", "text": ""],
      ],
      to: &data
    )
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.reasoning_summary_text.delta",
        "sequence_number": 3,
        "item_id": "reasoning_parts",
        "output_index": 0,
        "summary_index": 0,
        "delta": "A",
      ],
      to: &data
    )
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.reasoning_summary_part.added",
        "sequence_number": 4,
        "item_id": "reasoning_parts",
        "output_index": 0,
        "summary_index": 1,
        "part": ["type": "summary_text", "text": ""],
      ],
      to: &data
    )
    return data
  }

  private func appendMessageAdded(
    _ item: [String: Any],
    outputIndex: Int,
    sequence: inout Int,
    to data: inout Data
  ) throws {
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.output_item.added", "sequence_number": sequence,
        "output_index": outputIndex, "item": item,
      ],
      to: &data
    )
    sequence += 1
    let itemID = try #require(item["id"] as? String)
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.content_part.added", "sequence_number": sequence,
        "item_id": itemID, "output_index": outputIndex, "content_index": 0,
        "part": ["type": "output_text", "text": "", "annotations": []],
      ],
      to: &data
    )
    sequence += 1
  }

  private func appendTextDelta(
    _ delta: String,
    itemID: String,
    outputIndex: Int,
    sequence: inout Int,
    to data: inout Data
  ) throws {
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.output_text.delta", "sequence_number": sequence,
        "item_id": itemID, "output_index": outputIndex, "content_index": 0,
        "delta": delta,
      ],
      to: &data
    )
    sequence += 1
  }

  private func appendMessageDone(
    itemID: String,
    outputIndex: Int,
    text: String,
    item: [String: Any],
    sequence: inout Int,
    to data: inout Data
  ) throws {
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.output_text.done", "sequence_number": sequence,
        "item_id": itemID, "output_index": outputIndex, "content_index": 0, "text": text,
      ],
      to: &data
    )
    sequence += 1
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.content_part.done", "sequence_number": sequence,
        "item_id": itemID, "output_index": outputIndex, "content_index": 0,
        "part": ["type": "output_text", "text": text, "annotations": []],
      ],
      to: &data
    )
    sequence += 1
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.output_item.done", "sequence_number": sequence,
        "output_index": outputIndex, "item": item,
      ],
      to: &data
    )
    sequence += 1
  }

  private func isToolCall(_ event: InferenceStreamEvent) -> Bool {
    if case .toolCall = event { return true }
    return false
  }

  private func isCompletion(_ event: InferenceStreamEvent) -> Bool {
    if case .completed = event { return true }
    return false
  }

  private struct AuditResult: Sendable {
    let events: [InferenceStreamEvent]
    let error: OpenAIResponsesProviderError?
    let provider: OpenAIResponsesProvider?
  }

  private enum AuditOutcome: Equatable, Sendable {
    case success
    case provider(OpenAIResponsesProviderError)
  }
}
