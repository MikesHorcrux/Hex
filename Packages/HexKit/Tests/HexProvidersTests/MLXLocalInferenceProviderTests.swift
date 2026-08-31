import Foundation
import HexCore
import HexProviders
import Synchronization
import Testing

@Suite("MLX local inference provider")
struct MLXLocalInferenceProviderTests {
  @Test
  func publishesOneValidatedLifecycleAndReusesOneLoadedModel() async throws {
    let fixture = try makeFixture(modelNames: ["model-a"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let toolCall = ToolCall(
      id: ToolCallID(rawValue: "call-1"),
      name: "workspace_read_text_file",
      arguments: ["path": .string("README.md")]
    )
    let engine = ScriptedEngine(events: [
      .textDelta("Checking."),
      .toolCall(toolCall),
      .completed(
        usage: InferenceUsage(inputTokens: 12, outputTokens: 4),
        stopReason: .stop
      ),
    ])
    let loader = RecordingLoader(engines: ["model-a": engine])
    let provider = try makeProvider(fixture: fixture, loader: loader)
    let request = makeRequest(
      modelID: ModelID(rawValue: "model-a"),
      tools: [sampleTool],
      toolChoice: .required
    )

    let first = try await collect(provider, request: request)
    let second = try await collect(provider, request: request)

    #expect(
      first == [
        .started(providerResponseID: nil),
        .textDelta("Checking."),
        .toolCall(toolCall),
        .usage(InferenceUsage(inputTokens: 12, outputTokens: 4)),
        .completed(.toolCalls),
      ])
    #expect(second == first)
    #expect(await loader.loadCount() == 1)
  }

  @Test
  func keepsOnlyOneModelLoadedAndReloadsAfterSwitching() async throws {
    let fixture = try makeFixture(modelNames: ["model-a", "model-b"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let engine = ScriptedEngine(events: [
      .textDelta("done"),
      .completed(
        usage: InferenceUsage(inputTokens: 1, outputTokens: 1),
        stopReason: .stop
      ),
    ])
    let loader = RecordingLoader(engines: [
      "model-a": engine,
      "model-b": engine,
    ])
    let provider = try makeProvider(fixture: fixture, loader: loader)

    _ = try await collect(provider, request: makeRequest(modelID: ModelID(rawValue: "model-a")))
    _ = try await collect(provider, request: makeRequest(modelID: ModelID(rawValue: "model-b")))
    _ = try await collect(provider, request: makeRequest(modelID: ModelID(rawValue: "model-a")))

    #expect(await loader.loadedModelIDs() == ["model-a", "model-b", "model-a"])
  }

  @Test
  func advertisesOnlyCapabilitiesSharedByEveryConfiguredModel() async throws {
    let fixture = try makeFixture(modelNames: ["model-a", "model-b"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let modelADirectory = try #require(fixture.directories["model-a"])
    let modelA = try MLXLocalModelConfiguration(
      modelID: ModelID(rawValue: "model-a"),
      displayName: "Model A",
      directory: modelADirectory,
      maximumOutputTokens: 512,
      supportsToolCalling: true
    )
    let modelBDirectory = try #require(fixture.directories["model-b"])
    let modelB = try MLXLocalModelConfiguration(
      modelID: ModelID(rawValue: "model-b"),
      displayName: "Model B",
      directory: modelBDirectory,
      maximumOutputTokens: 512
    )
    let provider = try MLXLocalInferenceProvider(
      configuration: MLXLocalProviderConfiguration(
        providerID: ProviderID(rawValue: "mlx.local"),
        displayName: "On My Mac",
        models: [modelA, modelB]
      ),
      engineLoader: RecordingLoader(engines: [:])
    )

    #expect(provider.descriptor.capabilities == [.textInput, .streaming])
    #expect((try await provider.availableModels()).map(\.capabilities) == [
      [.textInput, .streaming, .toolCalling],
      [.textInput, .streaming],
    ])
    await #expect(throws: MLXLocalInferenceProviderError.invalidToolChoice) {
      _ = try await provider.stream(
        makeRequest(
          modelID: ModelID(rawValue: "model-b"),
          tools: [sampleTool],
          toolChoice: .required
        )
      )
    }
  }

  @Test
  func serializesGenerationAndReleasesTheProviderAfterCompletion() async throws {
    let fixture = try makeFixture(modelNames: ["model-a"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let engine = ControllableEngine()
    let loader = RecordingLoader(engines: ["model-a": engine])
    let provider = try makeProvider(fixture: fixture, loader: loader)
    let request = makeRequest(modelID: ModelID(rawValue: "model-a"))

    let firstStream = try await provider.stream(request)
    await #expect(throws: MLXLocalInferenceProviderError.busy) {
      _ = try await provider.stream(request)
    }

    await engine.complete()
    let firstEvents = try await collect(firstStream)
    #expect(firstEvents.last == .completed(.stop))

    let secondStream = try await provider.stream(request)
    await engine.complete()
    let secondEvents = try await collect(secondStream)
    #expect(secondEvents.last == .completed(.stop))
  }

  @Test
  func cancellingAConsumerReleasesTheSingleGenerationSlot() async throws {
    let fixture = try makeFixture(modelNames: ["model-a"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let engine = ControllableEngine()
    let loader = RecordingLoader(engines: ["model-a": engine])
    let provider = try makeProvider(fixture: fixture, loader: loader)
    let request = makeRequest(modelID: ModelID(rawValue: "model-a"))
    let firstStream = try await provider.stream(request)
    let consumer = Task {
      try await firstStream.consume { cursor in
        while try await cursor.next() != nil {}
      }
      try Task.checkCancellation()
    }

    await Task.yield()
    consumer.cancel()
    await #expect(throws: CancellationError.self) {
      try await consumer.value
    }

    var secondStream: InferenceStream?
    for _ in 0..<100 {
      do {
        secondStream = try await provider.stream(request)
        break
      } catch MLXLocalInferenceProviderError.busy {
        await Task.yield()
      }
    }
    let openedStream = try #require(secondStream)
    await engine.complete()
    await engine.complete()
    let events = try await collect(openedStream)
    #expect(events.last == .completed(.stop))
  }

  @Test
  func rejectsRemoteLocationsWrongRoutingAndOpaqueContinuation() async throws {
    let remoteURL = try #require(URL(string: "https://example.com/model"))
    #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      _ = try MLXLocalModelConfiguration(
        modelID: ModelID(rawValue: "remote"),
        displayName: "Remote",
        directory: remoteURL,
        maximumOutputTokens: 128
      )
    }

    let fixture = try makeFixture(modelNames: ["model-a"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let loader = RecordingLoader(engines: [
      "model-a": ScriptedEngine(events: [
        .completed(
          usage: InferenceUsage(inputTokens: 1, outputTokens: 0),
          stopReason: .stop
        )
      ])
    ])
    let provider = try makeProvider(fixture: fixture, loader: loader)

    await #expect(throws: MLXLocalInferenceProviderError.wrongProvider) {
      _ = try await provider.stream(
        InferenceRequest(
          providerID: ProviderID(rawValue: "other"),
          modelID: ModelID(rawValue: "model-a"),
          messages: [userMessage]
        )
      )
    }
    await #expect(throws: MLXLocalInferenceProviderError.unknownModel) {
      _ = try await provider.stream(makeRequest(modelID: ModelID(rawValue: "missing")))
    }
    await #expect(throws: MLXLocalInferenceProviderError.unsupportedContinuation) {
      _ = try await provider.stream(
        InferenceRequest(
          providerID: ProviderID(rawValue: "mlx.local"),
          modelID: ModelID(rawValue: "model-a"),
          previousProviderResponseID: "must-not-be-used",
          messages: [userMessage]
        )
      )
    }
    #expect(await loader.loadCount() == 0)
  }

  @Test
  func canonicalizesAndPinsTheSelectedModelDirectoryIdentity() throws {
    let fixture = try makeFixture(modelNames: ["model-a"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let directory = try #require(fixture.directories["model-a"])
    let selectedLink = fixture.root.appending(path: "selected-model")
    try FileManager.default.createSymbolicLink(
      at: selectedLink,
      withDestinationURL: directory
    )
    let configuration = try MLXLocalModelConfiguration(
      modelID: ModelID(rawValue: "model-a"),
      displayName: "Model A",
      directory: selectedLink,
      maximumOutputTokens: 512
    )

    #expect(configuration.directory == directory.resolvingSymlinksInPath())
    #expect(configuration.hasOriginalDirectoryIdentity())

    let movedDirectory = fixture.root.appending(path: "moved-model")
    try FileManager.default.moveItem(at: directory, to: movedDirectory)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false
    )
    #expect(!configuration.hasOriginalDirectoryIdentity())
  }

  @Test
  func rejectsRoleContentMismatchesBeforeLoadingTheModel() async throws {
    let fixture = try makeFixture(modelNames: ["model-a"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let loader = RecordingLoader(engines: [:])
    let provider = try makeProvider(fixture: fixture, loader: loader)
    let call = ToolCall(
      id: ToolCallID(rawValue: "call-1"),
      name: "workspace_read_text_file",
      arguments: [:]
    )
    let result = ToolResult(
      toolCallID: call.id,
      status: .success,
      output: .null,
      content: [.text("done")]
    )
    let invalidCall = ToolCall(
      id: ToolCallID(rawValue: ""),
      name: "",
      arguments: [:]
    )
    let invalidResult = ToolResult(
      toolCallID: ToolCallID(rawValue: ""),
      status: .success,
      output: .null,
      content: [.text("done")]
    )
    let invalidMessages = [
      Message(role: .user, content: [.toolCall(call)]),
      Message(role: .assistant, content: [.toolResult(result)]),
      Message(role: .tool, content: [.text("wrong role")]),
      Message(role: .assistant, content: [.toolCall(invalidCall)]),
      Message(role: .tool, content: [.toolResult(invalidResult)]),
    ]

    for message in invalidMessages {
      await #expect(throws: MLXLocalInferenceProviderError.invalidRequest) {
        _ = try await provider.stream(
          InferenceRequest(
            providerID: ProviderID(rawValue: "mlx.local"),
            modelID: ModelID(rawValue: "model-a"),
            messages: [message]
          )
        )
      }
    }
    #expect(await loader.loadCount() == 0)
  }

  @Test
  func rejectsDuplicateMessageIDsBeforeLoadingTheModel() async throws {
    let fixture = try makeFixture(modelNames: ["model-a"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let loader = RecordingLoader(engines: [:])
    let provider = try makeProvider(fixture: fixture, loader: loader)
    let messageID = MessageID()
    let duplicateMessages = [
      Message(id: messageID, role: .user, content: [.text("first")]),
      Message(id: messageID, role: .user, content: [.text("second")]),
    ]

    await #expect(throws: MLXLocalInferenceProviderError.invalidRequest) {
      _ = try await provider.stream(
        InferenceRequest(
          providerID: ProviderID(rawValue: "mlx.local"),
          modelID: ModelID(rawValue: "model-a"),
          messages: duplicateMessages
        )
      )
    }
    #expect(await loader.loadCount() == 0)
  }

  @Test
  func rejectsIncoherentAndOverdeepHistoryBeforeLoadingTheModel() async throws {
    let fixture = try makeFixture(modelNames: ["model-a"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let loader = RecordingLoader(engines: [:])
    let provider = try makeProvider(fixture: fixture, loader: loader)
    let orphanResult = ToolResult(
      toolCallID: ToolCallID(rawValue: "orphan"),
      status: .success,
      output: .null,
      content: [.text("done")]
    )
    var nestedValue = JSONValue.null
    for _ in 0..<80 {
      nestedValue = .array([nestedValue])
    }
    let nestedCall = ToolCall(
      id: ToolCallID(rawValue: "nested"),
      name: "nested_tool",
      arguments: ["value": nestedValue]
    )
    let invalidHistories = [
      [Message(role: .tool, content: [.toolResult(orphanResult)])],
      [Message(role: .assistant, content: [.text("")])],
      [Message(role: .assistant, content: [.toolCall(nestedCall)])],
    ]

    for messages in invalidHistories {
      await #expect(throws: MLXLocalInferenceProviderError.invalidRequest) {
        _ = try await provider.stream(
          InferenceRequest(
            providerID: ProviderID(rawValue: "mlx.local"),
            modelID: ModelID(rawValue: "model-a"),
            messages: messages
          )
        )
      }
    }
    #expect(await loader.loadCount() == 0)
  }

  @Test
  func enforcesToolChoiceAndParallelCapabilityAtTheProviderBoundary() async throws {
    let fixture = try makeFixture(modelNames: ["model-a"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let firstCall = ToolCall(
      id: ToolCallID(rawValue: "call-1"),
      name: "workspace_read_text_file",
      arguments: [:]
    )
    let secondCall = ToolCall(
      id: ToolCallID(rawValue: "call-2"),
      name: "workspace_read_text_file",
      arguments: [:]
    )
    let loader = RecordingLoader(engines: [
      "model-a": ScriptedEngine(events: [
        .toolCall(firstCall),
        .toolCall(secondCall),
        .completed(
          usage: InferenceUsage(inputTokens: 1, outputTokens: 1),
          stopReason: .stop
        ),
      ])
    ])
    let provider = try makeProvider(fixture: fixture, loader: loader)

    await #expect(throws: MLXLocalInferenceProviderError.invalidToolChoice) {
      _ = try await provider.stream(
        makeRequest(
          modelID: ModelID(rawValue: "model-a"),
          tools: [sampleTool],
          toolChoice: .named("missing")
        )
      )
    }
    do {
      _ = try await collect(
        provider,
        request: makeRequest(
          modelID: ModelID(rawValue: "model-a"),
          tools: [sampleTool],
          toolChoice: .automatic
        )
      )
      Issue.record("Expected a second tool call to fail for a nonparallel model.")
    } catch {
      #expect(error as? MLXLocalInferenceProviderError == .parallelToolCallsUnsupported)
    }
  }

  @Test
  func rejectsMissingDuplicateAndPostCompletionEngineEvents() async throws {
    let fixture = try makeFixture(modelNames: ["model-a"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    for (events, expectedError) in [
      ([MLXInferenceEngineEvent.textDelta("unfinished")], .incompleteStream),
      (
        [
          MLXInferenceEngineEvent.completed(
            usage: InferenceUsage(inputTokens: 1, outputTokens: 1),
            stopReason: .stop
          ),
          MLXInferenceEngineEvent.completed(
            usage: InferenceUsage(inputTokens: 1, outputTokens: 1),
            stopReason: .stop
          ),
        ],
        .invalidStream
      ),
      (
        [
          MLXInferenceEngineEvent.completed(
            usage: InferenceUsage(inputTokens: 1, outputTokens: 1),
            stopReason: .stop
          ),
          MLXInferenceEngineEvent.textDelta("late"),
        ],
        .invalidStream
      ),
    ] as [([MLXInferenceEngineEvent], MLXLocalInferenceProviderError)] {
      let loader = RecordingLoader(engines: ["model-a": ScriptedEngine(events: events)])
      let provider = try makeProvider(fixture: fixture, loader: loader)
      do {
        _ = try await collect(provider, request: makeRequest(modelID: ModelID(rawValue: "model-a")))
        Issue.record("Expected invalid engine lifecycle to fail.")
      } catch {
        #expect(error as? MLXLocalInferenceProviderError == expectedError)
      }
    }
  }

  @Test
  func withholdsTerminalEventsUntilPhysicalEOFAndRejectsTrailingOutput() async throws {
    let fixture = try makeFixture(modelNames: ["model-a"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let engine = GatedEngine(trailingEvent: .textDelta("late"))
    let loader = RecordingLoader(engines: ["model-a": engine])
    let provider = try makeProvider(fixture: fixture, loader: loader)
    let recorder = EventRecorder()
    let stream = try await provider.stream(
      makeRequest(modelID: ModelID(rawValue: "model-a"))
    )
    let collector = Task {
      do {
        try await stream.consume { cursor in
          while let event = try await cursor.next() {
            await recorder.record(event)
          }
        }
        return nil as MLXLocalInferenceProviderError?
      } catch {
        return error as? MLXLocalInferenceProviderError
      }
    }

    for _ in 0..<100 where await recorder.events().count < 2 {
      await Task.yield()
    }
    #expect(
      await recorder.events() == [
        .started(providerResponseID: nil),
        .textDelta("done"),
      ]
    )

    await engine.release()
    #expect(await collector.value == .invalidStream)
    #expect(
      await recorder.events() == [
        .started(providerResponseID: nil),
        .textDelta("done"),
      ]
    )
  }

  @Test
  func waitsForPhysicalTerminationAfterTheEngineEventStreamFinishes() async throws {
    let fixture = try makeFixture(modelNames: ["model-a"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let engine = EarlyFinishingEngine()
    let loader = RecordingLoader(engines: ["model-a": engine])
    let provider = try makeProvider(fixture: fixture, loader: loader)
    let recorder = EventRecorder()
    let stream = try await provider.stream(
      makeRequest(modelID: ModelID(rawValue: "model-a"))
    )
    let collector = Task {
      try await stream.consume { cursor in
        while let event = try await cursor.next() {
          await recorder.record(event)
        }
      }
    }

    for _ in 0..<100 {
      if await recorder.events().count >= 2 {
        break
      }
      await Task.yield()
    }
    #expect(
      await recorder.events() == [
        .started(providerResponseID: nil),
        .textDelta("done"),
      ]
    )

    await engine.release()
    try await collector.value
    #expect(
      await recorder.events() == [
        .started(providerResponseID: nil),
        .textDelta("done"),
        .usage(InferenceUsage(inputTokens: 1, outputTokens: 1)),
        .completed(.stop),
      ]
    )
  }

  @Test
  func rejectsIncoherentTerminalsUsageAndGeneratedArguments() async throws {
    let fixture = try makeFixture(modelNames: ["model-a"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var overdeep = JSONValue.null
    for _ in 0..<80 {
      overdeep = .array([overdeep])
    }
    let toolCall = ToolCall(
      id: ToolCallID(rawValue: "call-1"),
      name: "workspace_read_text_file",
      arguments: ["value": overdeep]
    )
    let shallowCall = ToolCall(
      id: ToolCallID(rawValue: "call-2"),
      name: "workspace_read_text_file",
      arguments: ["path": .string("README.md")]
    )
    let hostileEvents: [[MLXInferenceEngineEvent]] = [
      [
        .toolCall(shallowCall),
        .completed(
          usage: InferenceUsage(inputTokens: 1, outputTokens: 1),
          stopReason: .length
        ),
      ],
      [
        .completed(
          usage: InferenceUsage(inputTokens: 1, outputTokens: 0),
          stopReason: .stop
        )
      ],
      [
        .textDelta("impossible-with-zero-output-tokens"),
        .completed(
          usage: InferenceUsage(inputTokens: 1, outputTokens: 0),
          stopReason: .stop
        ),
      ],
      [
        .toolCall(shallowCall),
        .completed(
          usage: InferenceUsage(inputTokens: 1, outputTokens: 0),
          stopReason: .toolCalls
        ),
      ],
      [
        .textDelta("done"),
        .completed(
          usage: InferenceUsage(
            inputTokens: 1,
            outputTokens: 1,
            cachedInputTokens: 2
          ),
          stopReason: .stop
        ),
      ],
      [
        .textDelta("done"),
        .completed(
          usage: InferenceUsage(
            inputTokens: 1,
            outputTokens: 1,
            reasoningTokens: 2
          ),
          stopReason: .stop
        ),
      ],
      [
        .textDelta("done"),
        .completed(
          usage: InferenceUsage(inputTokens: 1, outputTokens: 129),
          stopReason: .length
        ),
      ],
      [
        .textDelta("done"),
        .completed(
          usage: InferenceUsage(inputTokens: 8_192, outputTokens: 1),
          stopReason: .stop
        ),
      ],
      [
        .toolCall(toolCall),
        .completed(
          usage: InferenceUsage(inputTokens: 1, outputTokens: 1),
          stopReason: .toolCalls
        ),
      ],
    ]

    for events in hostileEvents {
      let loader = RecordingLoader(engines: ["model-a": ScriptedEngine(events: events)])
      let provider = try makeProvider(fixture: fixture, loader: loader)
      do {
        _ = try await collect(
          provider,
          request: makeRequest(
            modelID: ModelID(rawValue: "model-a"),
            tools: [sampleTool]
          )
        )
        Issue.record("Expected hostile generated output to fail closed.")
      } catch {
        #expect(error as? MLXLocalInferenceProviderError == .invalidStream)
      }
    }
  }

  @Test
  func rejectsZeroInputUsageForANonemptyRequest() async throws {
    let fixture = try makeFixture(modelNames: ["model-a"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let loader = RecordingLoader(
      engines: [
        "model-a": ScriptedEngine(events: [
          .textDelta("impossible-with-zero-input-tokens"),
          .completed(
            usage: InferenceUsage(inputTokens: 0, outputTokens: 1),
            stopReason: .stop
          ),
        ])
      ]
    )
    let provider = try makeProvider(fixture: fixture, loader: loader)

    do {
      _ = try await collect(
        provider,
        request: makeRequest(modelID: ModelID(rawValue: "model-a"))
      )
      Issue.record("Expected zero input-token usage to fail closed.")
    } catch {
      #expect(error as? MLXLocalInferenceProviderError == .invalidStream)
    }
  }

  @Test
  func validatesGeneratedArgumentsAgainstSupportedInputSchema() async throws {
    let fixture = try makeFixture(modelNames: ["model-a"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let strictTool = ToolDefinition(
      name: "strict_read",
      description: "Read one path.",
      inputSchema: [
        "type": .string("object"),
        "properties": .object([
          "path": .object([
            "type": .string("string"),
            "minLength": .integer(1),
          ])
        ]),
        "required": .array([.string("path")]),
        "additionalProperties": .boolean(false),
      ]
    )
    let invalidArguments: [[String: JSONValue]] = [
      [:],
      ["path": .integer(1)],
      ["path": .string("")],
      ["path": .string("README.md"), "unexpected": .boolean(true)],
    ]

    for (index, arguments) in invalidArguments.enumerated() {
      let call = ToolCall(
        id: ToolCallID(rawValue: "invalid-\(index)"),
        name: strictTool.name,
        arguments: arguments
      )
      let loader = RecordingLoader(
        engines: [
          "model-a": ScriptedEngine(events: [
            .toolCall(call),
            .completed(
              usage: InferenceUsage(inputTokens: 1, outputTokens: 1),
              stopReason: .toolCalls
            ),
          ])
        ]
      )
      let provider = try makeProvider(fixture: fixture, loader: loader)
      do {
        _ = try await collect(
          provider,
          request: makeRequest(
            modelID: ModelID(rawValue: "model-a"),
            tools: [strictTool]
          )
        )
        Issue.record("Expected schema-mismatched generated arguments to fail closed.")
      } catch {
        #expect(error as? MLXLocalInferenceProviderError == .invalidStream)
      }
    }

    let validCall = ToolCall(
      id: ToolCallID(rawValue: "valid"),
      name: strictTool.name,
      arguments: ["path": .string("README.md")]
    )
    let validLoader = RecordingLoader(
      engines: [
        "model-a": ScriptedEngine(events: [
          .toolCall(validCall),
          .completed(
            usage: InferenceUsage(inputTokens: 1, outputTokens: 1),
            stopReason: .toolCalls
          ),
        ])
      ]
    )
    let validProvider = try makeProvider(fixture: fixture, loader: validLoader)
    let validEvents = try await collect(
      validProvider,
      request: makeRequest(
        modelID: ModelID(rawValue: "model-a"),
        tools: [strictTool]
      )
    )
    #expect(validEvents.contains(.toolCall(validCall)))
    #expect(validEvents.last == .completed(.toolCalls))

    let unsupportedTool = ToolDefinition(
      name: "unsupported_schema",
      description: "Uses a schema keyword outside the supported subset.",
      inputSchema: [
        "type": .string("object"),
        "properties": .object([
          "path": .object([
            "type": .string("string"),
            "pattern": .string(".+"),
          ])
        ]),
      ]
    )
    let rejectingLoader = RecordingLoader(engines: [:])
    let rejectingProvider = try makeProvider(fixture: fixture, loader: rejectingLoader)
    await #expect(throws: MLXLocalInferenceProviderError.invalidRequest) {
      _ = try await rejectingProvider.stream(
        makeRequest(
          modelID: ModelID(rawValue: "model-a"),
          tools: [unsupportedTool]
        )
      )
    }
    #expect(await rejectingLoader.loadCount() == 0)
  }

  @Test
  func keepsSlotBusyUntilCancellationIsPhysicallyAcknowledged() async throws {
    let fixture = try makeFixture(modelNames: ["model-a"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let engine = GatedEngine(
      trailingEvent: nil,
      waitsBeforeOutput: true
    )
    let loader = RecordingLoader(engines: ["model-a": engine])
    let provider = try makeProvider(fixture: fixture, loader: loader)
    let request = makeRequest(modelID: ModelID(rawValue: "model-a"))
    let stream = try await provider.stream(request)
    let consumer = Task {
      try await stream.consume { cursor in
        while try await cursor.next() != nil {}
      }
      try Task.checkCancellation()
    }

    for _ in 0..<100 where await engine.physicalRunCount() == 0 {
      await Task.yield()
    }
    consumer.cancel()
    for _ in 0..<1_000 where await engine.cancellationRequestCount() == 0 {
      await Task.yield()
    }
    let cancellationRequestCount = await engine.cancellationRequestCount()
    #expect(cancellationRequestCount == 1)
    await #expect(throws: MLXLocalInferenceProviderError.busy) {
      _ = try await provider.stream(request)
    }
    #expect(await engine.maximumConcurrentRuns() == 1)

    await engine.release()
    await #expect(throws: CancellationError.self) {
      try await consumer.value
    }
    var nextStream: InferenceStream?
    for _ in 0..<100 {
      do {
        nextStream = try await provider.stream(request)
        break
      } catch MLXLocalInferenceProviderError.busy {
        await Task.yield()
      }
    }
    let openedStream = try #require(nextStream)
    try await openedStream.consume { cursor in
      while try await cursor.next() != nil {}
    }
    #expect(await engine.maximumConcurrentRuns() == 1)
  }

  @Test
  func abandoningConsumerCancelsButKeepsSlotUntilPhysicalTermination() async throws {
    let fixture = try makeFixture(modelNames: ["model-a"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let engine = GatedEngine(
      trailingEvent: nil,
      waitsBeforeOutput: true
    )
    let loader = RecordingLoader(engines: ["model-a": engine])
    let provider = try makeProvider(fixture: fixture, loader: loader)
    let request = makeRequest(modelID: ModelID(rawValue: "model-a"))

    let abandonedStream = try await provider.stream(request)
    let consumer = Task {
      try await abandonedStream.consume { cursor in
        while let event = try await cursor.next() {
          if case .started = event {
            return
          }
        }
      }
    }
    for _ in 0..<1_000 where await engine.cancellationRequestCount() == 0 {
      await Task.yield()
    }

    let cancellationRequestCount = await engine.cancellationRequestCount()
    #expect(cancellationRequestCount == 1)
    #expect(await engine.physicalRunCount() == 1)
    await #expect(throws: MLXLocalInferenceProviderError.busy) {
      _ = try await provider.stream(request)
    }

    await engine.release()
    try await consumer.value
    var nextStream: InferenceStream?
    for _ in 0..<1_000 {
      do {
        nextStream = try await provider.stream(request)
        break
      } catch MLXLocalInferenceProviderError.busy {
        await Task.yield()
      }
    }
    let openedStream = try #require(nextStream)
    let events = try await collect(openedStream)
    #expect(events.last == .completed(.stop))
    #expect(await engine.maximumConcurrentRuns() == 1)
  }

  @Test
  func sanitizesLoaderAndGenerationFailuresButPreservesCancellation() async throws {
    let fixture = try makeFixture(modelNames: ["model-a"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let loaderFailure = RecordingLoader(
      engines: [:],
      failure: StubError.secret("TOKEN=loader-secret")
    )
    let loadProvider = try makeProvider(fixture: fixture, loader: loaderFailure)

    await #expect(throws: MLXLocalInferenceProviderError.modelLoadFailed) {
      _ = try await loadProvider.stream(makeRequest(modelID: ModelID(rawValue: "model-a")))
    }

    let generationFailure = RecordingLoader(engines: [
      "model-a": ScriptedEngine(
        events: [],
        terminalError: StubError.secret("TOKEN=generation-secret")
      )
    ])
    let generationProvider = try makeProvider(fixture: fixture, loader: generationFailure)
    do {
      _ = try await collect(
        generationProvider,
        request: makeRequest(modelID: ModelID(rawValue: "model-a"))
      )
      Issue.record("Expected generation failure.")
    } catch {
      #expect(error as? MLXLocalInferenceProviderError == .generationFailed)
      #expect(!String(describing: error).contains("secret"))
    }

    let cancelledLoader = RecordingLoader(engines: [:], failure: CancellationError())
    let cancelledProvider = try makeProvider(fixture: fixture, loader: cancelledLoader)
    await #expect(throws: CancellationError.self) {
      _ = try await cancelledProvider.stream(makeRequest(modelID: ModelID(rawValue: "model-a")))
    }
  }

  private var sampleTool: ToolDefinition {
    ToolDefinition(
      name: "workspace_read_text_file",
      description: "Read one file.",
      inputSchema: [
        "type": .string("object"),
        "properties": .object([
          "path": .object(["type": .string("string")])
        ]),
      ]
    )
  }

  private var userMessage: Message {
    Message(role: .user, content: [.text("Hello")])
  }

  private func makeRequest(
    modelID: ModelID,
    tools: [ToolDefinition] = [],
    toolChoice: ToolChoice = .automatic
  ) -> InferenceRequest {
    InferenceRequest(
      providerID: ProviderID(rawValue: "mlx.local"),
      modelID: modelID,
      messages: [userMessage],
      tools: tools,
      toolChoice: toolChoice,
      options: InferenceOptions(maxOutputTokens: 128, temperature: 0)
    )
  }

  private func makeFixture(
    modelNames: [String]
  ) throws -> (root: URL, directories: [String: URL]) {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "hex-mlx-provider-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var directories: [String: URL] = [:]
    for modelName in modelNames {
      let directory = root.appending(path: modelName, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      directories[modelName] = directory
    }
    return (root, directories)
  }

  private func makeProvider(
    fixture: (root: URL, directories: [String: URL]),
    loader: RecordingLoader
  ) throws -> MLXLocalInferenceProvider {
    let models = try fixture.directories.keys.sorted().map { modelName in
      let directory = try #require(fixture.directories[modelName])
      return try MLXLocalModelConfiguration(
        modelID: ModelID(rawValue: modelName),
        displayName: modelName,
        directory: directory,
        contextWindow: 8_192,
        maximumOutputTokens: 512,
        supportsToolCalling: true,
        supportsParallelToolCalling: false
      )
    }
    return try MLXLocalInferenceProvider(
      configuration: MLXLocalProviderConfiguration(
        providerID: ProviderID(rawValue: "mlx.local"),
        displayName: "On My Mac",
        models: models,
        maximumBufferedEvents: 8
      ),
      engineLoader: loader
    )
  }

  private func collect(
    _ provider: MLXLocalInferenceProvider,
    request: InferenceRequest
  ) async throws -> [InferenceStreamEvent] {
    let stream = try await provider.stream(request)
    return try await collect(stream)
  }

  private func collect(
    _ stream: InferenceStream
  ) async throws -> [InferenceStreamEvent] {
    try await stream.consume { cursor in
      var events: [InferenceStreamEvent] = []
      while let event = try await cursor.next() {
        events.append(event)
      }
      return events
    }
  }

  private actor RecordingLoader: MLXInferenceEngineLoader {
    private let engines: [String: any MLXInferenceEngine]
    private let failure: (any Error & Sendable)?
    private var loadedIDs: [String] = []

    init(
      engines: [String: any MLXInferenceEngine],
      failure: (any Error & Sendable)? = nil
    ) {
      self.engines = engines
      self.failure = failure
    }

    func loadModel(
      _ configuration: MLXLocalModelConfiguration
    ) async throws -> any MLXInferenceEngine {
      if let failure {
        throw failure
      }
      loadedIDs.append(configuration.modelID.rawValue)
      guard let engine = engines[configuration.modelID.rawValue] else {
        throw StubError.secret("missing test engine")
      }
      return engine
    }

    func loadCount() -> Int {
      loadedIDs.count
    }

    func loadedModelIDs() -> [String] {
      loadedIDs
    }
  }

  private struct ScriptedEngine: MLXInferenceEngine {
    let events: [MLXInferenceEngineEvent]
    let terminalError: (any Error & Sendable)?

    init(
      events: [MLXInferenceEngineEvent],
      terminalError: (any Error & Sendable)? = nil
    ) {
      self.events = events
      self.terminalError = terminalError
    }

    func start(
      _ request: InferenceRequest
    ) async throws -> MLXInferenceEngineRun {
      let stream = AsyncThrowingStream<MLXInferenceEngineEvent, any Error> { continuation in
        for event in events {
          continuation.yield(event)
        }
        if let terminalError {
          continuation.finish(throwing: terminalError)
        } else {
          continuation.finish()
        }
      }
      return MLXInferenceEngineRun(
        events: stream,
        cancel: {},
        waitForTermination: {}
      )
    }
  }

  private actor ControllableEngine: MLXInferenceEngine {
    private var continuations:
      [AsyncThrowingStream<MLXInferenceEngineEvent, any Error>.Continuation] = []

    func start(
      _ request: InferenceRequest
    ) async throws -> MLXInferenceEngineRun {
      let (stream, continuation) = AsyncThrowingStream.makeStream(
        of: MLXInferenceEngineEvent.self,
        throwing: (any Error).self
      )
      continuations.append(continuation)
      return MLXInferenceEngineRun(
        events: stream,
        cancel: {
          continuation.finish(throwing: CancellationError())
        },
        waitForTermination: {}
      )
    }

    func complete() {
      guard !continuations.isEmpty else {
        return
      }
      let continuation = continuations.removeFirst()
      continuation.yield(.textDelta("done"))
      continuation.yield(
        .completed(
          usage: InferenceUsage(inputTokens: 1, outputTokens: 1),
          stopReason: .stop
        )
      )
      continuation.finish()
    }
  }

  private actor EventRecorder {
    private var recordedEvents: [InferenceStreamEvent] = []

    func record(_ event: InferenceStreamEvent) {
      recordedEvents.append(event)
    }

    func events() -> [InferenceStreamEvent] {
      recordedEvents
    }
  }

  private actor EarlyFinishingEngine: MLXInferenceEngine {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func start(
      _ request: InferenceRequest
    ) async throws -> MLXInferenceEngineRun {
      let (stream, continuation) = AsyncThrowingStream.makeStream(
        of: MLXInferenceEngineEvent.self,
        throwing: (any Error).self
      )
      let producer = Task {
        continuation.yield(.textDelta("done"))
        continuation.yield(
          .completed(
            usage: InferenceUsage(inputTokens: 1, outputTokens: 1),
            stopReason: .stop
          )
        )
        continuation.finish()
        await self.waitForRelease()
      }
      return MLXInferenceEngineRun(
        events: stream,
        cancel: {
          producer.cancel()
        },
        waitForTermination: {
          await producer.value
        }
      )
    }

    func release() {
      released = true
      let pendingWaiters = waiters
      waiters.removeAll()
      for waiter in pendingWaiters {
        waiter.resume()
      }
    }

    private func waitForRelease() async {
      guard !released else {
        return
      }
      await withCheckedContinuation { continuation in
        waiters.append(continuation)
      }
    }
  }

  private actor GatedEngine: MLXInferenceEngine {
    private let trailingEvent: MLXInferenceEngineEvent?
    private let waitsBeforeOutput: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var activeRuns = 0
    private var maximumRuns = 0
    private let cancellationCounter = CancellationCounter()

    init(
      trailingEvent: MLXInferenceEngineEvent?,
      waitsBeforeOutput: Bool = false
    ) {
      self.trailingEvent = trailingEvent
      self.waitsBeforeOutput = waitsBeforeOutput
    }

    func start(
      _ request: InferenceRequest
    ) async throws -> MLXInferenceEngineRun {
      let (stream, continuation) = AsyncThrowingStream.makeStream(
        of: MLXInferenceEngineEvent.self,
        throwing: (any Error).self
      )
      let producer = Task {
        await self.run(continuation: continuation)
      }
      let cancellationCounter = cancellationCounter
      return MLXInferenceEngineRun(
        events: stream,
        cancel: {
          producer.cancel()
          cancellationCounter.increment()
        },
        waitForTermination: {
          await producer.value
        }
      )
    }

    func release() {
      released = true
      let pendingWaiters = waiters
      waiters.removeAll()
      for waiter in pendingWaiters {
        waiter.resume()
      }
    }

    func physicalRunCount() -> Int {
      activeRuns
    }

    func maximumConcurrentRuns() -> Int {
      maximumRuns
    }

    func cancellationRequestCount() -> Int {
      cancellationCounter.value()
    }

    private func run(
      continuation: AsyncThrowingStream<MLXInferenceEngineEvent, any Error>.Continuation
    ) async {
      activeRuns += 1
      maximumRuns = max(maximumRuns, activeRuns)
      if waitsBeforeOutput {
        await waitForRelease()
      }
      continuation.yield(.textDelta("done"))
      continuation.yield(
        .completed(
          usage: InferenceUsage(inputTokens: 1, outputTokens: 1),
          stopReason: .stop
        )
      )
      if !waitsBeforeOutput {
        await waitForRelease()
      }
      if let trailingEvent {
        continuation.yield(trailingEvent)
      }
      continuation.finish()
      activeRuns -= 1
    }

    private func waitForRelease() async {
      guard !released else {
        return
      }
      await withCheckedContinuation { continuation in
        waiters.append(continuation)
      }
    }

  }

  private final class CancellationCounter: Sendable {
    private let count = Mutex(0)

    func increment() {
      count.withLock { value in
        value += 1
      }
    }

    func value() -> Int {
      count.withLock { $0 }
    }
  }

  private enum StubError: Error, Sendable {
    case secret(String)
  }
}
