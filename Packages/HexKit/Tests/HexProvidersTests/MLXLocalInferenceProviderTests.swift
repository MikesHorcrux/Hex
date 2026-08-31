import Foundation
import HexCore
import HexProviders
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
      .completed(
        usage: InferenceUsage(inputTokens: 1, outputTokens: 0),
        stopReason: .stop
      )
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
    var firstEvents: [InferenceStreamEvent] = []
    for try await event in firstStream {
      firstEvents.append(event)
    }
    #expect(firstEvents.last == .completed(.stop))

    let secondStream = try await provider.stream(request)
    await engine.complete()
    var secondEvents: [InferenceStreamEvent] = []
    for try await event in secondStream {
      secondEvents.append(event)
    }
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
      for try await _ in firstStream {}
      try Task.checkCancellation()
    }

    await Task.yield()
    consumer.cancel()
    await #expect(throws: CancellationError.self) {
      try await consumer.value
    }

    var secondStream: AsyncThrowingStream<InferenceStreamEvent, any Error>?
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
    var events: [InferenceStreamEvent] = []
    for try await event in openedStream {
      events.append(event)
    }
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
    var events: [InferenceStreamEvent] = []
    for try await event in stream {
      events.append(event)
    }
    return events
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

    func stream(
      _ request: InferenceRequest
    ) async throws -> AsyncThrowingStream<MLXInferenceEngineEvent, any Error> {
      AsyncThrowingStream { continuation in
        for event in events {
          continuation.yield(event)
        }
        if let terminalError {
          continuation.finish(throwing: terminalError)
        } else {
          continuation.finish()
        }
      }
    }
  }

  private actor ControllableEngine: MLXInferenceEngine {
    private var continuations:
      [AsyncThrowingStream<MLXInferenceEngineEvent, any Error>.Continuation] = []

    func stream(
      _ request: InferenceRequest
    ) async throws -> AsyncThrowingStream<MLXInferenceEngineEvent, any Error> {
      let (stream, continuation) = AsyncThrowingStream.makeStream(
        of: MLXInferenceEngineEvent.self,
        throwing: (any Error).self
      )
      continuations.append(continuation)
      return stream
    }

    func complete() {
      guard !continuations.isEmpty else {
        return
      }
      let continuation = continuations.removeFirst()
      continuation.yield(
        .completed(
          usage: InferenceUsage(inputTokens: 1, outputTokens: 0),
          stopReason: .stop
        )
      )
      continuation.finish()
    }
  }

  private enum StubError: Error, Sendable {
    case secret(String)
  }
}
