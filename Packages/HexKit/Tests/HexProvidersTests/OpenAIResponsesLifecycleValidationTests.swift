import Foundation
import HexCore
import Testing

@testable import HexProviders

@Suite("OpenAI Responses lifecycle validation")
struct OpenAIResponsesLifecycleValidationTests {
  @Test
  func rejectsEveryContradictoryOrMissingProgressStatusWithoutCommit() async throws {
    let cases: [(type: String, status: String?)] = [
      ("response.queued", "in_progress"),
      ("response.queued", "failed"),
      ("response.queued", nil),
      ("response.in_progress", "queued"),
      ("response.in_progress", "failed"),
      ("response.in_progress", nil),
    ]

    for mode in privacyModes {
      for (index, probe) in cases.enumerated() {
        let responseID = "resp_progress_pair_\(mode.rawValue)_\(index)"
        let streamData = try minimalTerminalStream(
          responseID: responseID,
          createdStatus: "in_progress",
          progress: [(probe.type, probe.status, responseID)],
          terminalType: "response.completed",
          terminalStatus: "completed",
          terminalID: responseID
        )
        let (provider, result) = try await run(
          streamData,
          responseID: responseID,
          privacyMode: mode
        )

        #expect(
          result.error == .malformedStream,
          Comment(
            rawValue: "Expected \(probe.type) carrying \(probe.status ?? "missing") to fail"
          )
        )
        #expect(!result.events.contains(where: isCompletion))
        #expect(await provider.serverStates[responseID] == nil)
        #expect(await provider.localStates[responseID] == nil)
      }
    }
  }

  @Test
  func rejectsDuplicateAndRegressiveProgressTransitionsWithoutCommit() async throws {
    let cases: [[(type: String, status: String?, identifier: String)]] = [
      [("response.queued", "queued", "same")],
      [
        ("response.in_progress", "in_progress", "same"),
        ("response.queued", "queued", "same"),
      ],
      [
        ("response.queued", "queued", "same"),
        ("response.queued", "queued", "same"),
      ],
      [
        ("response.in_progress", "in_progress", "same"),
        ("response.in_progress", "in_progress", "same"),
      ],
    ]

    for mode in privacyModes {
      for (index, rawProgress) in cases.enumerated() {
        let responseID = "resp_progress_order_\(mode.rawValue)_\(index)"
        let progress = rawProgress.map { event in
          (
            event.type,
            event.status,
            event.identifier == "same" ? responseID : event.identifier
          )
        }
        let streamData = try minimalTerminalStream(
          responseID: responseID,
          createdStatus: "in_progress",
          progress: progress,
          terminalType: "response.completed",
          terminalStatus: "completed",
          terminalID: responseID
        )
        let (provider, result) = try await run(
          streamData,
          responseID: responseID,
          privacyMode: mode
        )

        #expect(
          result.error == .malformedStream,
          Comment(rawValue: "Expected progress transition case \(index) to fail")
        )
        #expect(!result.events.contains(where: isCompletion))
        #expect(await provider.serverStates[responseID] == nil)
        #expect(await provider.localStates[responseID] == nil)
      }
    }
  }

  @Test
  func rejectsProgressTransitionsAfterOutputStarts() async throws {
    let cases = [
      (createdStatus: "queued", type: "response.queued", status: "queued"),
      (
        createdStatus: "in_progress",
        type: "response.in_progress",
        status: "in_progress"
      ),
    ]

    for mode in privacyModes {
      for (index, probe) in cases.enumerated() {
        let responseID = "resp_late_progress_\(mode.rawValue)_\(index)"
        let streamData = try progressAfterOutputStream(
          responseID: responseID,
          createdStatus: probe.createdStatus,
          progressType: probe.type,
          progressStatus: probe.status
        )
        let (provider, result) = try await run(
          streamData,
          responseID: responseID,
          privacyMode: mode,
          tools: [weatherTool]
        )

        #expect(result.error == .malformedStream)
        #expect(!result.events.contains(where: isDeferredTerminalPublication))
        #expect(await provider.serverStates[responseID] == nil)
        #expect(await provider.localStates[responseID] == nil)
      }
    }
  }

  @Test
  func contradictoryInProgressStatusCannotPublishCompletionOrCommit() async throws {
    for mode in privacyModes {
      let responseID = "resp_bad_progress_commit_\(mode.rawValue)"
      let streamData = try functionCallStream(
        responseID: responseID,
        progressStatus: "failed"
      )
      let (provider, result) = try await run(
        streamData,
        responseID: responseID,
        privacyMode: mode,
        tools: [weatherTool]
      )

      #expect(result.error == .malformedStream)
      #expect(!result.events.contains(where: isDeferredTerminalPublication))
      #expect(await provider.serverStates[responseID] == nil)
      #expect(await provider.localStates[responseID] == nil)
    }
  }

  @Test
  func rejectsFailedAndCancelledEventsWithWrongIdentityOrStatus() async throws {
    let cases: [(type: String, status: String, identifier: String)] = [
      ("response.failed", "failed", "foreign"),
      ("response.failed", "completed", "same"),
      ("response.cancelled", "cancelled", "foreign"),
      ("response.cancelled", "completed", "same"),
    ]

    for mode in privacyModes {
      for (index, probe) in cases.enumerated() {
        let responseID = "resp_invalid_failure_\(mode.rawValue)_\(index)"
        let streamData = try failureStream(
          responseID: responseID,
          eventType: probe.type,
          terminalID: probe.identifier == "same" ? responseID : probe.identifier,
          terminalStatus: probe.status,
          message: "private-failure-payload"
        )
        let (provider, result) = try await run(
          streamData,
          responseID: responseID,
          privacyMode: mode
        )

        #expect(result.error == .malformedStream)
        #expect(!result.events.contains(where: isCompletion))
        #expect(await provider.serverStates[responseID] == nil)
        #expect(await provider.localStates[responseID] == nil)
      }
    }
  }

  @Test
  func validFailedCancelledAndErrorEventsAreRedactedAndNeverCommit() async throws {
    let cases: [(type: String, status: String?)] = [
      ("response.failed", "failed"),
      ("response.cancelled", "cancelled"),
      ("error", nil),
    ]

    for mode in privacyModes {
      for (index, probe) in cases.enumerated() {
        let responseID = "resp_valid_failure_\(mode.rawValue)_\(index)"
        let streamData: Data
        if let status = probe.status {
          streamData = try failureStream(
            responseID: responseID,
            eventType: probe.type,
            terminalID: responseID,
            terminalStatus: status,
            message: "private-failure-payload"
          )
        } else {
          streamData = try errorStream(
            responseID: responseID,
            message: "private-failure-payload"
          )
        }
        let (provider, result) = try await run(
          streamData,
          responseID: responseID,
          privacyMode: mode
        )

        #expect(result.error == .responseFailed)
        #expect(!result.events.contains(where: isCompletion))
        #expect(await provider.serverStates[responseID] == nil)
        #expect(await provider.localStates[responseID] == nil)
        #expect(
          !OpenAIResponsesProviderError.responseFailed.localizedDescription.contains(
            "private-failure-payload"
          )
        )
      }
    }
  }

  @Test
  func validatesTerminalTypeStatusAndResponseIdentityWithoutCommit() async throws {
    let cases: [(type: String, status: String, identifier: String)] = [
      ("response.completed", "incomplete", "same"),
      ("response.incomplete", "completed", "same"),
      ("response.completed", "completed", "foreign"),
      ("response.incomplete", "incomplete", "foreign"),
    ]

    for mode in privacyModes {
      for (index, probe) in cases.enumerated() {
        let responseID = "resp_terminal_pair_\(mode.rawValue)_\(index)"
        let streamData = try minimalTerminalStream(
          responseID: responseID,
          createdStatus: "in_progress",
          progress: [],
          terminalType: probe.type,
          terminalStatus: probe.status,
          terminalID: probe.identifier == "same" ? responseID : probe.identifier
        )
        let (provider, result) = try await run(
          streamData,
          responseID: responseID,
          privacyMode: mode
        )

        #expect(result.error == .malformedStream)
        #expect(!result.events.contains(where: isCompletion))
        #expect(await provider.serverStates[responseID] == nil)
        #expect(await provider.localStates[responseID] == nil)
      }
    }
  }

  @Test
  func validatesCreatedStatusAndProgressResponseIdentityWithoutCommit() async throws {
    let invalidCreatedStatuses = ["completed", "incomplete", "failed", "cancelled"]
    for mode in privacyModes {
      for (index, status) in invalidCreatedStatuses.enumerated() {
        let responseID = "resp_invalid_created_\(mode.rawValue)_\(index)"
        let streamData = try minimalTerminalStream(
          responseID: responseID,
          createdStatus: status,
          progress: [],
          terminalType: "response.completed",
          terminalStatus: "completed",
          terminalID: responseID
        )
        let (provider, result) = try await run(
          streamData,
          responseID: responseID,
          privacyMode: mode
        )

        #expect(result.error == .malformedStream)
        #expect(!result.events.contains(where: isCompletion))
        #expect(await provider.serverStates[responseID] == nil)
        #expect(await provider.localStates[responseID] == nil)
      }

      for (index, progressType) in ["response.queued", "response.in_progress"].enumerated() {
        let responseID = "resp_foreign_progress_\(mode.rawValue)_\(index)"
        let expectedStatus = progressType == "response.queued" ? "queued" : "in_progress"
        let streamData = try minimalTerminalStream(
          responseID: responseID,
          createdStatus: "in_progress",
          progress: [(progressType, expectedStatus, "foreign")],
          terminalType: "response.completed",
          terminalStatus: "completed",
          terminalID: responseID
        )
        let (provider, result) = try await run(
          streamData,
          responseID: responseID,
          privacyMode: mode
        )

        #expect(result.error == .malformedStream)
        #expect(!result.events.contains(where: isCompletion))
        #expect(await provider.serverStates[responseID] == nil)
        #expect(await provider.localStates[responseID] == nil)
      }
    }
  }

  @Test
  func acceptsValidProgressAndTerminalTransitionsWithoutCrossModeState() async throws {
    let progressCases: [(createdStatus: String, progress: [(String, String?, String)])] = [
      (
        "queued",
        [("response.queued", "queued", "same"), ("response.in_progress", "in_progress", "same")]
      ),
      ("in_progress", [("response.in_progress", "in_progress", "same")]),
      ("in_progress", []),
    ]
    let terminalCases = [
      ("response.completed", "completed"),
      ("response.incomplete", "incomplete"),
    ]

    for mode in privacyModes {
      for (progressIndex, progressCase) in progressCases.enumerated() {
        for (terminalType, terminalStatus) in terminalCases {
          let responseID =
            "resp_valid_lifecycle_\(mode.rawValue)_\(progressIndex)_\(terminalStatus)"
          let progress = progressCase.progress.map { event in
            (
              event.0,
              event.1,
              event.2 == "same" ? responseID : event.2
            )
          }
          let streamData = try minimalTerminalStream(
            responseID: responseID,
            createdStatus: progressCase.createdStatus,
            progress: progress,
            terminalType: terminalType,
            terminalStatus: terminalStatus,
            terminalID: responseID,
            successfulText: terminalStatus == "completed" ? "ok" : nil
          )
          let (provider, result) = try await run(
            streamData,
            responseID: responseID,
            privacyMode: mode
          )

          #expect(result.error == nil)
          #expect(result.events.contains(where: isCompletion))
          if mode == .serverManagedContinuation {
            #expect(await provider.serverStates[responseID] != nil)
            #expect(await provider.localStates[responseID] == nil)
          } else {
            #expect(await provider.serverStates[responseID] == nil)
            #expect(await provider.localStates[responseID] == nil)
          }
        }
      }
    }
  }

  private let privacyModes: [OpenAIResponsesPrivacyMode] = [
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

  private func run(
    _ streamData: Data,
    responseID: String,
    privacyMode: OpenAIResponsesPrivacyMode,
    tools: [ToolDefinition] = []
  ) async throws -> (OpenAIResponsesProvider, ProbeResult) {
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(privacyMode: privacyMode),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-lifecycle-test"),
      transport: TestOpenAIResponsesTransport(
        responses: [OpenAIResponsesTestFixture.response(data: streamData)]
      )
    )
    let recorder = OpenAIInferenceEventRecorder()
    do {
      let stream = try await provider.stream(OpenAIResponsesTestFixture.request(tools: tools))
      try await stream.consume { cursor in
        while let event = try await cursor.next() {
          await recorder.record(event)
        }
      }
      return (provider, ProbeResult(events: await recorder.events(), error: nil))
    } catch let error as OpenAIResponsesProviderError {
      return (provider, ProbeResult(events: await recorder.events(), error: error))
    } catch is CancellationError {
      Issue.record("Unexpected cancellation for \(responseID).")
      return (provider, ProbeResult(events: await recorder.events(), error: nil))
    } catch {
      Issue.record("Unexpected error type for \(responseID).")
      return (provider, ProbeResult(events: await recorder.events(), error: nil))
    }
  }

  private func minimalTerminalStream(
    responseID: String,
    createdStatus: String,
    progress: [(String, String?, String)],
    terminalType: String,
    terminalStatus: String,
    terminalID: String,
    successfulText: String? = nil
  ) throws -> Data {
    var data = Data()
    var sequenceNumber = 0
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.created",
        "sequence_number": sequenceNumber,
        "response": ["id": responseID, "status": createdStatus],
      ],
      to: &data
    )
    sequenceNumber += 1

    for (type, status, identifier) in progress {
      var response: [String: Any] = ["id": identifier]
      if let status {
        response["status"] = status
      }
      try OpenAIResponsesTestFixture.appendEvent(
        [
          "type": type,
          "sequence_number": sequenceNumber,
          "response": response,
        ],
        to: &data
      )
      sequenceNumber += 1
    }

    var terminalOutput: [[String: Any]] = []
    if let successfulText {
      let addedItem: [String: Any] = [
        "id": "msg_\(responseID)",
        "type": "message",
        "status": "in_progress",
        "role": "assistant",
        "content": [],
      ]
      let completedItem: [String: Any] = [
        "id": "msg_\(responseID)",
        "type": "message",
        "status": "completed",
        "role": "assistant",
        "content": [
          [
            "type": "output_text",
            "text": successfulText,
            "annotations": [],
          ]
        ],
      ]
      try OpenAIResponsesTestFixture.appendEvent(
        [
          "type": "response.output_item.added",
          "sequence_number": sequenceNumber,
          "output_index": 0,
          "item": addedItem,
        ],
        to: &data
      )
      sequenceNumber += 1
      try OpenAIResponsesTestFixture.appendEvent(
        [
          "type": "response.content_part.added",
          "sequence_number": sequenceNumber,
          "item_id": "msg_\(responseID)",
          "output_index": 0,
          "content_index": 0,
          "part": ["type": "output_text", "text": "", "annotations": []],
        ],
        to: &data
      )
      sequenceNumber += 1
      try OpenAIResponsesTestFixture.appendEvent(
        [
          "type": "response.output_text.delta",
          "sequence_number": sequenceNumber,
          "item_id": "msg_\(responseID)",
          "output_index": 0,
          "content_index": 0,
          "delta": successfulText,
        ],
        to: &data
      )
      sequenceNumber += 1
      try OpenAIResponsesTestFixture.appendEvent(
        [
          "type": "response.output_text.done",
          "sequence_number": sequenceNumber,
          "item_id": "msg_\(responseID)",
          "output_index": 0,
          "content_index": 0,
          "text": successfulText,
        ],
        to: &data
      )
      sequenceNumber += 1
      try OpenAIResponsesTestFixture.appendEvent(
        [
          "type": "response.content_part.done",
          "sequence_number": sequenceNumber,
          "item_id": "msg_\(responseID)",
          "output_index": 0,
          "content_index": 0,
          "part": ["type": "output_text", "text": successfulText, "annotations": []],
        ],
        to: &data
      )
      sequenceNumber += 1
      try OpenAIResponsesTestFixture.appendEvent(
        [
          "type": "response.output_item.done",
          "sequence_number": sequenceNumber,
          "output_index": 0,
          "item": completedItem,
        ],
        to: &data
      )
      sequenceNumber += 1
      terminalOutput = [completedItem]
    }

    var terminalResponse: [String: Any] = [
      "id": terminalID,
      "status": terminalStatus,
      "output": terminalOutput,
    ]
    if terminalStatus == "incomplete" {
      terminalResponse["incomplete_details"] = ["reason": "max_output_tokens"]
    }
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": terminalType,
        "sequence_number": sequenceNumber,
        "response": terminalResponse,
      ],
      to: &data
    )
    return data
  }

  private func failureStream(
    responseID: String,
    eventType: String,
    terminalID: String,
    terminalStatus: String,
    message: String
  ) throws -> Data {
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
        "type": eventType,
        "sequence_number": 1,
        "message": message,
        "response": ["id": terminalID, "status": terminalStatus],
      ],
      to: &data
    )
    return data
  }

  private func functionCallStream(responseID: String, progressStatus: String) throws -> Data {
    let itemID = "fc_\(responseID)"
    let callID = "call_\(responseID)"
    let addedItem: [String: Any] = [
      "id": itemID,
      "type": "function_call",
      "call_id": callID,
      "name": "lookup_weather",
      "arguments": "",
      "status": "in_progress",
    ]
    let completedItem: [String: Any] = [
      "id": itemID,
      "type": "function_call",
      "call_id": callID,
      "name": "lookup_weather",
      "arguments": "{}",
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
        "type": "response.in_progress",
        "sequence_number": 1,
        "response": ["id": responseID, "status": progressStatus],
      ],
      to: &data
    )
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.output_item.added",
        "sequence_number": 2,
        "output_index": 0,
        "item": addedItem,
      ],
      to: &data
    )
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.function_call_arguments.delta",
        "sequence_number": 3,
        "item_id": itemID,
        "output_index": 0,
        "delta": "{}",
      ],
      to: &data
    )
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.function_call_arguments.done",
        "sequence_number": 4,
        "item_id": itemID,
        "output_index": 0,
        "call_id": callID,
        "name": "lookup_weather",
        "arguments": "{}",
      ],
      to: &data
    )
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.output_item.done",
        "sequence_number": 5,
        "output_index": 0,
        "item": completedItem,
      ],
      to: &data
    )
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.completed",
        "sequence_number": 6,
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

  private func progressAfterOutputStream(
    responseID: String,
    createdStatus: String,
    progressType: String,
    progressStatus: String
  ) throws -> Data {
    let itemID = "fc_\(responseID)"
    var data = Data()
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.created",
        "sequence_number": 0,
        "response": ["id": responseID, "status": createdStatus],
      ],
      to: &data
    )
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.output_item.added",
        "sequence_number": 1,
        "output_index": 0,
        "item": [
          "id": itemID,
          "type": "function_call",
          "call_id": "call_\(responseID)",
          "name": "lookup_weather",
          "arguments": "",
          "status": "in_progress",
        ],
      ],
      to: &data
    )
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": progressType,
        "sequence_number": 2,
        "response": ["id": responseID, "status": progressStatus],
      ],
      to: &data
    )
    return data
  }

  private func errorStream(responseID: String, message: String) throws -> Data {
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
        "type": "error",
        "sequence_number": 1,
        "message": message,
      ],
      to: &data
    )
    return data
  }

  private func isCompletion(_ event: InferenceStreamEvent) -> Bool {
    if case .completed = event {
      return true
    }
    return false
  }

  private func isDeferredTerminalPublication(_ event: InferenceStreamEvent) -> Bool {
    switch event {
    case .toolCall, .usage, .completed:
      true
    case .started, .textDelta, .reasoningSummaryDelta:
      false
    }
  }

  private struct ProbeResult: Sendable {
    let events: [InferenceStreamEvent]
    let error: OpenAIResponsesProviderError?
  }
}
