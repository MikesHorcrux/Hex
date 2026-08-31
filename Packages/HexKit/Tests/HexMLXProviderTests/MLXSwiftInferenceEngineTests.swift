import Foundation
import HexCore
import HexProviders
import MLXLMCommon
import Testing

@testable import HexMLXProvider

@Suite("MLX Swift inference engine")
struct MLXSwiftInferenceEngineTests {
  @Test
  func withholdsCompletionUntilTheGenerationSequenceReachesPhysicalEOF() async throws {
    let gate = GenerationGate()
    let engine = MLXSwiftInferenceEngine(
      modelID: ModelID(rawValue: "model"),
      defaultMaximumOutputTokens: 128,
      generationRuns: { _, _, _ in
        let (stream, continuation) = AsyncStream.makeStream(of: Generation.self)
        let physicalGeneration = Task {
          continuation.yield(.chunk("done"))
          continuation.yield(
            .info(
              GenerateCompletionInfo(
                promptTokenCount: 1,
                generationTokenCount: 1,
                promptTime: 0.1,
                generationTime: 0.1,
                stopReason: .stop
              )
            )
          )
          await gate.wait()
          continuation.finish()
        }
        continuation.onTermination = { @Sendable _ in
          physicalGeneration.cancel()
        }
        return MLXSwiftGenerationRun(
          events: stream,
          cancel: {
            physicalGeneration.cancel()
          },
          waitForTermination: {
            await physicalGeneration.value
          }
        )
      }
    )
    let request = InferenceRequest(
      providerID: ProviderID(rawValue: "mlx.local"),
      modelID: ModelID(rawValue: "model"),
      messages: [Message(role: .user, content: [.text("Hello")])],
      options: InferenceOptions(maxOutputTokens: 128, temperature: 0)
    )
    let run = try await engine.start(request)
    let recorder = EngineEventRecorder()
    let collector = Task {
      for try await event in run.events {
        await recorder.record(event)
      }
    }

    await recorder.waitForEventCount(1)
    #expect(await recorder.events() == [.textDelta("done")])

    await gate.release()
    try await collector.value
    await run.waitForTermination()
    #expect(
      await recorder.events() == [
        .textDelta("done"),
        .completed(
          usage: InferenceUsage(inputTokens: 1, outputTokens: 1),
          stopReason: .stop
        ),
      ]
    )
  }

  @Test
  func rejectsContextOverflowBeforeCreatingTheTokenIterator() throws {
    try MLXSwiftInferenceEngine.validateContext(
      promptTokenCount: 96,
      maximumOutputTokens: 32,
      maximumContextTokens: 128
    )
    #expect(throws: MLXLocalInferenceProviderError.invalidRequest) {
      try MLXSwiftInferenceEngine.validateContext(
        promptTokenCount: 97,
        maximumOutputTokens: 32,
        maximumContextTokens: 128
      )
    }
    #expect(throws: MLXLocalInferenceProviderError.invalidRequest) {
      try MLXSwiftInferenceEngine.validateContext(
        promptTokenCount: Int.max,
        maximumOutputTokens: 32,
        maximumContextTokens: 128
      )
    }
  }

  @Test
  func rejectsPreparedPromptWithZeroTokensBeforeCreatingTheTokenIterator() {
    #expect(throws: MLXLocalInferenceProviderError.invalidRequest) {
      try MLXSwiftInferenceEngine.validateContext(
        promptTokenCount: 0,
        maximumOutputTokens: 32,
        maximumContextTokens: 128
      )
    }
  }

  @Test
  func rejectsSnapshotReplacementBeforeInjectedGenerationStarts() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "hex-mlx-generation-snapshot-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let modelDirectory = root.appending(path: "model", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: modelDirectory,
      withIntermediateDirectories: false
    )
    try Data("{\"model_type\":\"test\"}".utf8).write(
      to: modelDirectory.appending(path: "config.json")
    )
    try Data("{}".utf8).write(to: modelDirectory.appending(path: "tokenizer.json"))
    try Data("weights".utf8).write(
      to: modelDirectory.appending(path: "model.safetensors")
    )
    let configuration = try MLXLocalModelConfiguration(
      modelID: ModelID(rawValue: "model"),
      displayName: "Model",
      directory: modelDirectory,
      maximumOutputTokens: 128
    )
    let generationAttempts = GenerationAttemptProbe()
    let paths = try await exerciseReplacedSnapshotAtGenerationBoundary(
      configuration: configuration,
      root: root,
      generationAttempts: generationAttempts
    )
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: paths.capturedSnapshot.path
      )
      try? FileManager.default.removeItem(at: paths.replacement)
      try? FileManager.default.removeItem(at: root)
    }

    #expect(await generationAttempts.count() == 0)
    #expect(
      try Data(contentsOf: paths.replacement.appending(path: "sentinel"))
        == Data("unrelated".utf8)
    )
  }

  @Test
  func providerKeepsSlotUntilCancellationIgnoringPhysicalGenerationStops() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "hex-mlx-physical-generation-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let physicalGeneration = PhysicalGenerationProbe()
    let engine = MLXSwiftInferenceEngine(
      modelID: ModelID(rawValue: "model"),
      defaultMaximumOutputTokens: 128,
      generationRuns: { _, _, _ in
        let (stream, continuation) = AsyncStream.makeStream(of: Generation.self)
        let task = Task {
          await physicalGeneration.beginAndWaitIgnoringCancellation()
          continuation.yield(.chunk("done"))
          continuation.yield(
            .info(
              GenerateCompletionInfo(
                promptTokenCount: 1,
                generationTokenCount: 1,
                promptTime: 0.1,
                generationTime: 0.1,
                stopReason: .stop
              )
            )
          )
          continuation.finish()
          await physicalGeneration.finish()
        }
        continuation.onTermination = { @Sendable _ in
          task.cancel()
        }
        return MLXSwiftGenerationRun(
          events: stream,
          cancel: {
            task.cancel()
          },
          waitForTermination: {
            await task.value
          }
        )
      }
    )
    let model = try MLXLocalModelConfiguration(
      modelID: ModelID(rawValue: "model"),
      displayName: "Model",
      directory: directory,
      maximumOutputTokens: 128
    )
    let provider = try MLXLocalInferenceProvider(
      configuration: MLXLocalProviderConfiguration(
        providerID: ProviderID(rawValue: "mlx.local"),
        displayName: "MLX Local",
        models: [model]
      ),
      engineLoader: FixedEngineLoader(engine: engine)
    )
    let request = InferenceRequest(
      providerID: ProviderID(rawValue: "mlx.local"),
      modelID: ModelID(rawValue: "model"),
      messages: [Message(role: .user, content: [.text("Hello")])],
      options: InferenceOptions(maxOutputTokens: 128, temperature: 0)
    )
    let firstStream = try await provider.stream(request)
    let firstConsumer = Task {
      try await firstStream.consume { cursor in
        while try await cursor.next() != nil {}
      }
      try Task.checkCancellation()
    }

    for _ in 0..<1_000 where await physicalGeneration.activeRunCount() == 0 {
      await Task.yield()
    }
    #expect(await physicalGeneration.activeRunCount() == 1)
    firstConsumer.cancel()
    await #expect(throws: MLXLocalInferenceProviderError.busy) {
      _ = try await provider.stream(request)
    }

    await physicalGeneration.release()
    await #expect(throws: CancellationError.self) {
      try await firstConsumer.value
    }
    var secondStream: InferenceStream?
    for _ in 0..<1_000 {
      do {
        secondStream = try await provider.stream(request)
        break
      } catch MLXLocalInferenceProviderError.busy {
        await Task.yield()
      }
    }
    let openedSecondStream = try #require(secondStream)
    let secondEvents = try await openedSecondStream.consume { cursor in
      var events: [InferenceStreamEvent] = []
      while let event = try await cursor.next() {
        events.append(event)
      }
      return events
    }
    #expect(secondEvents.last == .completed(.stop))
    #expect(await physicalGeneration.activeRunCount() == 0)
    #expect(await physicalGeneration.maximumConcurrentRunCount() == 1)
  }

  private func exerciseReplacedSnapshotAtGenerationBoundary(
    configuration: MLXLocalModelConfiguration,
    root: URL,
    generationAttempts: GenerationAttemptProbe
  ) async throws -> (capturedSnapshot: URL, replacement: URL) {
    let namespace = try MLXModelArtifactSnapshotNamespace(
      directory: root.appending(
        path: "snapshot-namespace",
        directoryHint: .isDirectory
      ),
      snapshotLimit: 1
    )
    let snapshot = try MLXModelArtifactSnapshotBuilder(namespace: namespace).makeSnapshot(
      for: configuration
    )
    let capturedSnapshot = root.appending(
      path: "captured-snapshot",
      directoryHint: .isDirectory
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: snapshot.directory.path
    )
    try FileManager.default.moveItem(at: snapshot.directory, to: capturedSnapshot)
    try FileManager.default.createDirectory(
      at: snapshot.directory,
      withIntermediateDirectories: false
    )
    try Data("unrelated".utf8).write(
      to: snapshot.directory.appending(path: "sentinel")
    )
    let engine = MLXSwiftInferenceEngine(
      modelID: ModelID(rawValue: "model"),
      defaultMaximumOutputTokens: 128,
      artifactSnapshot: snapshot,
      generationRuns: { _, _, _ in
        await generationAttempts.record()
        throw MLXLocalInferenceProviderError.generationFailed
      }
    )
    let request = InferenceRequest(
      providerID: ProviderID(rawValue: "mlx.local"),
      modelID: ModelID(rawValue: "model"),
      messages: [Message(role: .user, content: [.text("Hello")])],
      options: InferenceOptions(maxOutputTokens: 128, temperature: 0)
    )

    await #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      _ = try await engine.start(request)
    }
    return (capturedSnapshot, snapshot.directory)
  }

  private actor EngineEventRecorder {
    private var recordedEvents: [MLXInferenceEngineEvent] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record(_ event: MLXInferenceEngineEvent) {
      recordedEvents.append(event)
      let readyWaiters = waiters.filter { $0.count <= recordedEvents.count }
      waiters.removeAll { $0.count <= recordedEvents.count }
      for waiter in readyWaiters {
        waiter.continuation.resume()
      }
    }

    func events() -> [MLXInferenceEngineEvent] {
      recordedEvents
    }

    func waitForEventCount(_ count: Int) async {
      guard recordedEvents.count < count else {
        return
      }
      await withCheckedContinuation { continuation in
        waiters.append((count, continuation))
      }
    }
  }

  private actor GenerationGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func wait() async {
      guard !released else {
        return
      }
      await withCheckedContinuation { continuation in
        waiters.append(continuation)
      }
    }

    func release() {
      released = true
      let pendingWaiters = waiters
      waiters.removeAll()
      for waiter in pendingWaiters {
        waiter.resume()
      }
    }
  }

  private actor GenerationAttemptProbe {
    private var attempts = 0

    func record() {
      attempts += 1
    }

    func count() -> Int {
      attempts
    }
  }

  private actor PhysicalGenerationProbe {
    private var activeRuns = 0
    private var maximumConcurrentRuns = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func beginAndWaitIgnoringCancellation() async {
      activeRuns += 1
      maximumConcurrentRuns = max(maximumConcurrentRuns, activeRuns)
      if !released {
        await withCheckedContinuation { continuation in
          waiters.append(continuation)
        }
      }
    }

    func finish() {
      activeRuns -= 1
    }

    func release() {
      released = true
      let pendingWaiters = waiters
      waiters.removeAll()
      for waiter in pendingWaiters {
        waiter.resume()
      }
    }

    func activeRunCount() -> Int {
      activeRuns
    }

    func maximumConcurrentRunCount() -> Int {
      maximumConcurrentRuns
    }
  }

  private struct FixedEngineLoader: MLXInferenceEngineLoader {
    let engine: any MLXInferenceEngine

    func loadModel(
      _ configuration: MLXLocalModelConfiguration
    ) async throws -> any MLXInferenceEngine {
      engine
    }
  }
}
