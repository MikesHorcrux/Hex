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
      generations: { _, _ in
        let (stream, continuation) = AsyncThrowingStream.makeStream(
          of: Generation.self,
          throwing: (any Error).self
        )
        let producer = Task {
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
          producer.cancel()
        }
        return stream
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
}
