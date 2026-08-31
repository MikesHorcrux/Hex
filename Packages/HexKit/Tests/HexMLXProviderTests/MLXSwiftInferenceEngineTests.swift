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

    for _ in 0..<100 {
      if await recorder.events().count == 1 {
        break
      }
      await Task.yield()
    }
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
      for try await _ in firstStream {}
      try Task.checkCancellation()
    }

    for _ in 0..<1_000 where await physicalGeneration.activeRunCount() == 0 {
      await Task.yield()
    }
    #expect(await physicalGeneration.activeRunCount() == 1)
    firstConsumer.cancel()
    await #expect(throws: CancellationError.self) {
      try await firstConsumer.value
    }
    await #expect(throws: MLXLocalInferenceProviderError.busy) {
      _ = try await provider.stream(request)
    }

    await physicalGeneration.release()
    var secondStream: AsyncThrowingStream<InferenceStreamEvent, any Error>?
    for _ in 0..<1_000 {
      do {
        secondStream = try await provider.stream(request)
        break
      } catch MLXLocalInferenceProviderError.busy {
        await Task.yield()
      }
    }
    let openedSecondStream = try #require(secondStream)
    var secondEvents: [InferenceStreamEvent] = []
    for try await event in openedSecondStream {
      secondEvents.append(event)
    }
    #expect(secondEvents.last == .completed(.stop))
    #expect(await physicalGeneration.activeRunCount() == 0)
    #expect(await physicalGeneration.maximumConcurrentRunCount() == 1)
  }

  private actor EngineEventRecorder {
    private var recordedEvents: [MLXInferenceEngineEvent] = []

    func record(_ event: MLXInferenceEngineEvent) {
      recordedEvents.append(event)
    }

    func events() -> [MLXInferenceEngineEvent] {
      recordedEvents
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
