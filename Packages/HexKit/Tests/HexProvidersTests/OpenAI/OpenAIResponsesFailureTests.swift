import Foundation
import HexCore
import Testing

@testable import HexProviders

@Suite("OpenAI Responses failure boundaries")
struct OpenAIResponsesFailureTests {
  @Test
  func classifiesOnlyTransientProviderFailuresAsRetryable() {
    #expect(!OpenAIResponsesProviderError.invalidRequest.isRetryable)
    #expect(!OpenAIResponsesProviderError.credentialUnavailable.isRetryable)
    #expect(!OpenAIResponsesProviderError.httpFailure(statusCode: 400).isRetryable)
    #expect(OpenAIResponsesProviderError.httpFailure(statusCode: 429).isRetryable)
    #expect(OpenAIResponsesProviderError.httpFailure(statusCode: 503).isRetryable)
    #expect(OpenAIResponsesProviderError.transportFailed.isRetryable)
  }

  @Test
  func reportsUnexpectedMediaTypeWithoutReadingTheResponseBody() async throws {
    let transport = TestOpenAIResponsesTransport(
      responses: [
        OpenAIResponsesTestFixture.response(
          data: Data("private response body".utf8),
          statusCode: 200,
          contentType: "application/json; charset=utf-8"
        )
      ]
    )
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-client-secret"),
      transport: transport
    )

    do {
      _ = try await provider.stream(OpenAIResponsesTestFixture.request())
      Issue.record("Expected an unexpected content type failure.")
    } catch let error as OpenAIResponsesProviderError {
      #expect(error.localizedDescription.contains("application/json"))
      #expect(!error.localizedDescription.contains("private response body"))
      #expect(!error.localizedDescription.contains("sk-client-secret"))
    } catch {
      Issue.record("Expected a redacted provider error.")
    }
  }

  @Test
  func rejectsCredentialExfiltrationEndpointsDuringConfiguration() throws {
    let invalidEndpoints = [
      "https://attacker.example.test/v1/responses",
      "https://api.openai.com/v1/chat/completions",
      "https://api.openai.com:8443/v1/responses",
      "https://api.openai.com/v1/responses?redirect=attacker",
      "https://user@api.openai.com/v1/responses",
    ]

    for endpointString in invalidEndpoints {
      let endpoint = try #require(URL(string: endpointString))
      do {
        _ = try OpenAIResponsesConfiguration(
          endpoint: endpoint,
          models: [OpenAIResponsesTestFixture.model()]
        )
        Issue.record("Expected noncanonical OpenAI endpoint to be rejected.")
      } catch let error as OpenAIResponsesProviderError {
        #expect(error == .invalidConfiguration)
      } catch {
        Issue.record("Expected OpenAIResponsesProviderError.invalidConfiguration.")
      }
    }

    let explicitTLS = try #require(URL(string: "https://api.openai.com:443/v1/responses"))
    _ = try OpenAIResponsesConfiguration(
      endpoint: explicitTLS,
      models: [OpenAIResponsesTestFixture.model()]
    )
  }

  @Test
  func redactsNonSuccessBodiesCredentialsAndPrompts() async throws {
    let secretBody = Data("server leaked sk-server-secret and private prompt".utf8)
    let transport = TestOpenAIResponsesTransport(
      responses: [
        OpenAIResponsesTestFixture.response(
          data: secretBody,
          statusCode: 401,
          contentType: "application/json"
        )
      ]
    )
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-client-secret"),
      transport: transport
    )
    let request = OpenAIResponsesTestFixture.request(
      messages: [Message(role: .user, content: [.text("private prompt")])]
    )

    do {
      _ = try await provider.stream(request)
      Issue.record("Expected the non-success response to throw.")
    } catch let error as OpenAIResponsesProviderError {
      #expect(error == .httpFailure(statusCode: 401))
      let publicText = error.localizedDescription
      #expect(!publicText.contains("sk-client-secret"))
      #expect(!publicText.contains("sk-server-secret"))
      #expect(!publicText.contains("private prompt"))
    } catch {
      Issue.record("Expected a redacted provider error.")
    }
  }

  @Test
  func boundsWorstCaseJSONEscapingBeforeTransport() async throws {
    let transport = TestOpenAIResponsesTransport(responses: [])
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(
        maximumInputValueBytes: 1_024,
        maximumRequestBodyBytes: 256
      ),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-json-bound"),
      transport: transport
    )
    let controlCharacters = String(repeating: "\u{0001}", count: 80)

    do {
      _ = try await provider.stream(
        OpenAIResponsesTestFixture.request(
          messages: [Message(role: .user, content: [.text(controlCharacters)])]
        )
      )
      Issue.record("Expected escaped request body to exceed its configured bound.")
    } catch let error as OpenAIResponsesProviderError {
      #expect(error == .invalidRequest)
    } catch {
      Issue.record("Expected OpenAIResponsesProviderError.invalidRequest.")
    }
    #expect(await transport.requests().isEmpty)
  }

  @Test
  func wrapsCredentialProviderFailuresWithoutLeakingTheirText() async throws {
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(),
      credentialProvider: FailingCredentialProvider(),
      transport: TestOpenAIResponsesTransport(responses: [])
    )

    do {
      _ = try await provider.stream(OpenAIResponsesTestFixture.request())
      Issue.record("Expected credential lookup to throw.")
    } catch let error as OpenAIResponsesProviderError {
      #expect(error == .credentialUnavailable)
      #expect(!error.localizedDescription.contains("credential-secret"))
    } catch {
      Issue.record("Expected a redacted provider error.")
    }
  }

  @Test
  func rejectsDuplicateAndOutOfOrderLifecycleEvents() async throws {
    var duplicate = Data()
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.created",
        "sequence_number": 0,
        "response": ["id": "resp_duplicate", "status": "in_progress"],
      ],
      to: &duplicate
    )
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.created",
        "sequence_number": 1,
        "response": ["id": "resp_duplicate", "status": "in_progress"],
      ],
      to: &duplicate
    )

    var outOfOrder = Data()
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.created",
        "sequence_number": 4,
        "response": ["id": "resp_order", "status": "in_progress"],
      ],
      to: &outOfOrder
    )
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.in_progress",
        "sequence_number": 3,
        "response": ["id": "resp_order", "status": "in_progress"],
      ],
      to: &outOfOrder
    )

    for streamData in [duplicate, outOfOrder] {
      let error = await providerError(for: streamData)
      #expect(error == .malformedStream)
    }
  }

  @Test
  func rejectsMissingAndContradictoryTextDeltas() async throws {
    let missingDelta = try textLifecycleStream(
      deltas: [],
      doneText: "Hello",
      completedText: "Hello"
    )
    #expect(await providerError(for: missingDelta) == .malformedStream)

    let contradictoryDone = try textLifecycleStream(
      deltas: ["Hello"],
      doneText: "Different",
      completedText: "Different"
    )
    #expect(await providerError(for: contradictoryDone) == .malformedStream)
  }

  @Test
  func rejectsDuplicateAndOutOfOrderTextPartLifecycle() async throws {
    let duplicateAdded = try textLifecycleStream(
      deltas: ["Hello"],
      doneText: "Hello",
      completedText: "Hello",
      duplicatePartAdded: true
    )
    #expect(await providerError(for: duplicateAdded) == .malformedStream)

    let doneBeforeTextDone = try textLifecycleStream(
      deltas: ["Hello"],
      doneText: "Hello",
      completedText: "Hello",
      partDoneBeforeTextDone: true
    )
    #expect(await providerError(for: doneBeforeTextDone) == .malformedStream)
  }

  @Test
  func rejectsCompletedOutputThatContradictsAssembledText() async throws {
    let streamData = try textLifecycleStream(
      deltas: ["Hello"],
      doneText: "Hello",
      completedText: "Different"
    )
    #expect(await providerError(for: streamData) == .malformedStream)
  }

  @Test
  func rejectsTrailingEventsBeforePublishingToolCallsOrCompletion() async throws {
    var streamData = try OpenAIResponsesTestFixture.toolStream(
      responseID: "resp_trailing",
      callID: "call_trailing"
    )
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.in_progress",
        "sequence_number": 100,
        "response": ["id": "resp_trailing", "status": "in_progress"],
      ],
      to: &streamData
    )
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-trailing"),
      transport: TestOpenAIResponsesTransport(
        responses: [OpenAIResponsesTestFixture.response(data: streamData)]
      )
    )

    let recorder = OpenAIInferenceEventRecorder()
    do {
      let stream = try await provider.stream(
        OpenAIResponsesTestFixture.request(tools: [weatherTool()])
      )
      try await stream.consume { cursor in
        while let event = try await cursor.next() {
          await recorder.record(event)
        }
      }
      Issue.record("Expected trailing event to fail the stream.")
    } catch let error as OpenAIResponsesProviderError {
      #expect(error == .malformedStream)
    } catch {
      Issue.record("Expected OpenAIResponsesProviderError.malformedStream.")
    }

    let receivedEvents = await recorder.events()
    #expect(
      receivedEvents.allSatisfy { event in
        switch event {
        case .toolCall, .usage, .completed:
          false
        case .started, .textDelta, .reasoningSummaryDelta:
          true
        }
      }
    )
  }

  @Test
  func boundsCumulativeTextAcrossManySmallDeltas() async throws {
    let delta = String(repeating: "a", count: 180)
    let streamData = try textLifecycleStream(
      deltas: [delta, delta, delta],
      doneText: String(repeating: "a", count: 540),
      completedText: String(repeating: "a", count: 540)
    )
    let configuration = try OpenAIResponsesTestFixture.configuration(
      maximumSSELineBytes: 512,
      maximumSSEEventBytes: 512,
      maximumResponseBytes: 16_384,
      maximumToolArgumentBytes: 512
    )
    let eventOffsets = eventBoundaryOffsets(in: streamData)
    let eventChunks = OpenAIResponsesTestFixture.split(streamData, at: eventOffsets)
    #expect(streamData.count < configuration.maximumResponseBytes)
    #expect(eventChunks.prefix(6).allSatisfy { $0.count <= 512 })
    #expect(
      await providerError(
        for: streamData,
        configuration: configuration,
        splitAt: eventOffsets
      )
        == .streamEventLimitExceeded
    )
  }

  @Test
  func rejectsOversizedLineEventResponseAndToolArguments() async throws {
    let lineConfiguration = try OpenAIResponsesTestFixture.configuration(
      maximumSSELineBytes: 32,
      maximumSSEEventBytes: 64,
      maximumResponseBytes: 256,
      maximumToolArgumentBytes: 64
    )
    let lineError = await providerError(
      for: Data(repeating: 0x61, count: 33),
      configuration: lineConfiguration
    )
    #expect(lineError == .streamFramingLimitExceeded(.lineBytes))

    let eventConfiguration = try OpenAIResponsesTestFixture.configuration(
      maximumSSELineBytes: 80,
      maximumSSEEventBytes: 100,
      maximumResponseBytes: 512,
      maximumToolArgumentBytes: 100
    )
    var oversizedEvent = Data("data: ".utf8)
    oversizedEvent.append(Data(repeating: 0x61, count: 70))
    oversizedEvent.append(Data("\ndata: ".utf8))
    oversizedEvent.append(Data(repeating: 0x62, count: 40))
    oversizedEvent.append(Data("\n\n".utf8))
    let eventError = await providerError(
      for: oversizedEvent,
      configuration: eventConfiguration
    )
    #expect(eventError == .streamFramingLimitExceeded(.eventBytes))

    let responseConfiguration = try OpenAIResponsesTestFixture.configuration(
      maximumSSELineBytes: 64,
      maximumSSEEventBytes: 128,
      maximumResponseBytes: 160,
      maximumToolArgumentBytes: 128
    )
    var oversizedResponse = Data()
    for _ in 0..<20 {
      oversizedResponse.append(Data(": padding\n".utf8))
    }
    let responseError = await providerError(
      for: oversizedResponse,
      configuration: responseConfiguration
    )
    #expect(responseError == .streamFramingLimitExceeded(.responseBytes))

    let argumentsConfiguration = try OpenAIResponsesTestFixture.configuration(
      maximumToolArgumentBytes: 8
    )
    let toolData = try OpenAIResponsesTestFixture.toolStream(
      responseID: "resp_large_arguments",
      callID: "call_large"
    )
    let argumentError = await providerError(
      for: toolData,
      configuration: argumentsConfiguration,
      tools: [weatherTool()]
    )
    #expect(argumentError == .streamEventLimitExceeded)
  }

  @Test
  func rejectsTruncatedAndMalformedJSONStreams() async throws {
    var truncated = Data()
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.created",
        "sequence_number": 0,
        "response": ["id": "resp_truncated", "status": "in_progress"],
      ],
      to: &truncated
    )
    #expect(await providerError(for: truncated) == .truncatedStream)

    let malformed = Data("data: {not-json}\n\n".utf8)
    #expect(await providerError(for: malformed) == .malformedStream)
  }

  @Test
  func rejectsMissingEncryptedReasoningInLocalMode() async throws {
    let original = try OpenAIResponsesTestFixture.toolStream(
      responseID: "resp_no_encrypted",
      callID: "call_no_encrypted"
    )
    let originalString = try #require(String(data: original, encoding: .utf8))
    let modified = originalString.replacingOccurrences(
      of: "\"encrypted_content\":\"encrypted-state\",",
      with: ""
    )
    let configuration = try OpenAIResponsesTestFixture.configuration(
      privacyMode: .localEphemeralReplay
    )

    let error = await providerError(
      for: Data(modified.utf8),
      configuration: configuration,
      tools: [weatherTool()]
    )
    #expect(error == .encryptedReasoningUnavailable)
  }

  @Test
  func propagatesTransportCancellationAsCancellationError() async throws {
    let transport = SuspendingTransport()
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-cancel"),
      transport: transport
    )
    let requestTask = Task {
      try await provider.stream(OpenAIResponsesTestFixture.request())
    }
    await Task.yield()
    requestTask.cancel()

    do {
      _ = try await requestTask.value
      Issue.record("Expected CancellationError.")
    } catch is CancellationError {
      // Exact cancellation propagation is the provider contract.
    } catch {
      Issue.record("Expected CancellationError.")
    }
  }

  @Test
  func redactsServerErrorEvents() async throws {
    var streamData = Data()
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.created",
        "sequence_number": 0,
        "response": ["id": "resp_error", "status": "in_progress"],
      ],
      to: &streamData
    )
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "error",
        "sequence_number": 1,
        "message": "private prompt sk-event-secret",
        "code": "server_error",
      ],
      to: &streamData
    )

    let error = await providerError(for: streamData)
    #expect(error == .responseFailed)
    #expect(error?.localizedDescription.contains("private prompt") == false)
    #expect(error?.localizedDescription.contains("sk-event-secret") == false)
  }

  private func providerError(
    for streamData: Data,
    configuration: OpenAIResponsesConfiguration? = nil,
    tools: [ToolDefinition] = [],
    splitAt offsets: [Int] = []
  ) async -> OpenAIResponsesProviderError? {
    do {
      let transport = TestOpenAIResponsesTransport(
        responses: [OpenAIResponsesTestFixture.response(data: streamData, splitAt: offsets)]
      )
      let resolvedConfiguration: OpenAIResponsesConfiguration
      if let configuration {
        resolvedConfiguration = configuration
      } else {
        resolvedConfiguration = try OpenAIResponsesTestFixture.configuration()
      }
      let provider = OpenAIResponsesProvider(
        configuration: resolvedConfiguration,
        credentialProvider: TestOpenAICredentialProvider(key: "sk-failure"),
        transport: transport
      )
      _ = try await OpenAIResponsesTestFixture.collect(
        provider: provider,
        request: OpenAIResponsesTestFixture.request(tools: tools)
      )
      Issue.record("Expected provider failure.")
      return nil
    } catch let error as OpenAIResponsesProviderError {
      return error
    } catch is CancellationError {
      Issue.record("Unexpected cancellation.")
      return nil
    } catch {
      Issue.record("Unexpected error type.")
      return nil
    }
  }

  private func eventBoundaryOffsets(in data: Data) -> [Int] {
    guard data.count >= 2 else { return [] }
    var offsets: [Int] = []
    for index in 1..<data.count where data[index - 1] == 0x0A && data[index] == 0x0A {
      offsets.append(index + 1)
    }
    return offsets
  }

  private func textLifecycleStream(
    deltas: [String],
    doneText: String,
    completedText: String,
    duplicatePartAdded: Bool = false,
    partDoneBeforeTextDone: Bool = false
  ) throws -> Data {
    let responseID = "resp_text_lifecycle"
    let itemID = "msg_text_lifecycle"
    let addedItem: [String: Any] = [
      "id": itemID,
      "type": "message",
      "status": "in_progress",
      "role": "assistant",
      "content": [],
    ]
    let completedItem: [String: Any] = [
      "id": itemID,
      "type": "message",
      "status": "completed",
      "role": "assistant",
      "content": [["type": "output_text", "text": completedText, "annotations": []]],
    ]
    let addedPart: [String: Any] = ["type": "output_text", "text": "", "annotations": []]
    let completedPart: [String: Any] = [
      "type": "output_text", "text": doneText, "annotations": [],
    ]
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
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.output_item.added",
        "sequence_number": sequence,
        "output_index": 0,
        "item": addedItem,
      ],
      to: &data
    )
    sequence += 1

    func appendPartEvent(type: String, part: [String: Any]) throws {
      try OpenAIResponsesTestFixture.appendEvent(
        [
          "type": type,
          "sequence_number": sequence,
          "item_id": itemID,
          "output_index": 0,
          "content_index": 0,
          "part": part,
        ],
        to: &data
      )
      sequence += 1
    }

    try appendPartEvent(type: "response.content_part.added", part: addedPart)
    if duplicatePartAdded {
      try appendPartEvent(type: "response.content_part.added", part: addedPart)
    }
    if partDoneBeforeTextDone {
      try appendPartEvent(type: "response.content_part.done", part: completedPart)
    }

    for delta in deltas {
      try OpenAIResponsesTestFixture.appendEvent(
        [
          "type": "response.output_text.delta",
          "sequence_number": sequence,
          "item_id": itemID,
          "output_index": 0,
          "content_index": 0,
          "delta": delta,
        ],
        to: &data
      )
      sequence += 1
    }
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.output_text.done",
        "sequence_number": sequence,
        "item_id": itemID,
        "output_index": 0,
        "content_index": 0,
        "text": doneText,
      ],
      to: &data
    )
    sequence += 1
    if !partDoneBeforeTextDone {
      try appendPartEvent(type: "response.content_part.done", part: completedPart)
    }
    try OpenAIResponsesTestFixture.appendEvent(
      [
        "type": "response.output_item.done",
        "sequence_number": sequence,
        "output_index": 0,
        "item": completedItem,
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
          "output": [completedItem],
        ],
      ],
      to: &data
    )
    return data
  }

  private func weatherTool() -> ToolDefinition {
    ToolDefinition(
      name: "lookup_weather",
      description: "Look up weather for a city.",
      inputSchema: ["type": .string("object")]
    )
  }

  struct FailingCredentialProvider: OpenAICredentialProvider {
    func apiKey() async throws -> String {
      throw CredentialFailure.secret("credential-secret")
    }
  }

  enum CredentialFailure: Error {
    case secret(String)
  }

  actor SuspendingTransport: OpenAIResponsesTransport {
    func send(_ request: URLRequest) async throws -> OpenAIResponsesTransportResponse {
      try await Task.sleep(for: .seconds(3_600))
      return OpenAIResponsesTransportResponse(
        statusCode: 200,
        body: AsyncThrowingStream { continuation in
          continuation.finish()
        },
        cancel: {},
        waitForTermination: {}
      )
    }
  }
}
