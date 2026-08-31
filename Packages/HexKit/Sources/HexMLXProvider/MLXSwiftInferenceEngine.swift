import HexCore
import HexProviders
import MLXLMCommon

struct MLXSwiftInferenceEngine: MLXInferenceEngine, Sendable {
  private let modelID: ModelID
  private let defaultMaximumOutputTokens: Int
  private let maximumBufferedEvents: Int
  private let artifactSnapshot: MLXModelArtifactSnapshot?
  private let generations:
    @Sendable (InferenceRequest, Int) throws -> AsyncThrowingStream<Generation, any Error>

  init(
    model: ModelContainer,
    modelID: ModelID,
    defaultMaximumOutputTokens: Int,
    artifactSnapshot: MLXModelArtifactSnapshot,
    maximumBufferedEvents: Int = 64
  ) {
    self.modelID = modelID
    self.defaultMaximumOutputTokens = defaultMaximumOutputTokens
    self.artifactSnapshot = artifactSnapshot
    self.maximumBufferedEvents = maximumBufferedEvents
    generations = { request, maximumOutputTokens in
      let messages = try MLXSwiftRequestMapper.messages(for: request)
      let tools = try MLXSwiftRequestMapper.toolSpecifications(for: request)
      let parameters = GenerateParameters(
        maxTokens: maximumOutputTokens,
        temperature: Float(request.options.temperature ?? 0.6)
      )
      let session = ChatSession(
        model,
        generateParameters: parameters,
        tools: tools
      )
      return session.streamDetails(to: messages)
    }
  }

  init(
    modelID: ModelID,
    defaultMaximumOutputTokens: Int,
    maximumBufferedEvents: Int = 64,
    generations:
      @escaping @Sendable (
        InferenceRequest,
        Int
      ) throws -> AsyncThrowingStream<Generation, any Error>
  ) {
    self.modelID = modelID
    self.defaultMaximumOutputTokens = defaultMaximumOutputTokens
    self.maximumBufferedEvents = maximumBufferedEvents
    artifactSnapshot = nil
    self.generations = generations
  }

  func start(
    _ request: InferenceRequest
  ) async throws -> MLXInferenceEngineRun {
    try Task.checkCancellation()
    let maximumOutputTokens = request.options.maxOutputTokens ?? defaultMaximumOutputTokens
    guard
      request.modelID == modelID,
      (1...defaultMaximumOutputTokens).contains(maximumOutputTokens),
      request.options.temperature.map({
        $0.isFinite && (0...2).contains($0)
      }) ?? true
    else {
      throw MLXLocalInferenceProviderError.invalidRequest
    }

    let (stream, continuation) = AsyncThrowingStream.makeStream(
      of: MLXInferenceEngineEvent.self,
      throwing: (any Error).self,
      bufferingPolicy: .bufferingOldest(maximumBufferedEvents)
    )
    let producer = Task {
      do {
        try Task.checkCancellation()
        let generationStream = try generations(request, maximumOutputTokens)
        try Task.checkCancellation()
        var pendingTerminal: (InferenceUsage, InferenceStopReason)?

        for try await generation in generationStream {
          try Task.checkCancellation()
          guard pendingTerminal == nil else {
            throw MLXLocalInferenceProviderError.invalidStream
          }
          switch generation {
          case .chunk(let text):
            guard !text.isEmpty else {
              continue
            }
            try Self.yield(.textDelta(text), to: continuation)

          case .toolCall(let toolCall):
            try Self.yield(
              .toolCall(try MLXSwiftRequestMapper.coreToolCall(toolCall)),
              to: continuation
            )

          case .info(let info):
            guard
              let inputTokens = UInt64(exactly: info.promptTokenCount),
              let outputTokens = UInt64(exactly: info.generationTokenCount)
            else {
              throw MLXLocalInferenceProviderError.invalidStream
            }
            let stopReason: InferenceStopReason
            switch info.stopReason {
            case .stop:
              stopReason = .stop
            case .length:
              stopReason = .length
            case .cancelled:
              throw CancellationError()
            }
            pendingTerminal = (
              InferenceUsage(
                inputTokens: inputTokens,
                outputTokens: outputTokens
              ),
              stopReason
            )
          }
        }
        guard let (usage, stopReason) = pendingTerminal else {
          throw MLXLocalInferenceProviderError.incompleteStream
        }
        try Self.yield(
          .completed(usage: usage, stopReason: stopReason),
          to: continuation
        )
        continuation.finish()
      } catch is CancellationError {
        continuation.finish(throwing: CancellationError())
      } catch let error as MLXLocalInferenceProviderError {
        continuation.finish(throwing: error)
      } catch {
        continuation.finish(throwing: MLXLocalInferenceProviderError.generationFailed)
      }
    }
    continuation.onTermination = { @Sendable _ in
      producer.cancel()
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

  private static func yield(
    _ event: MLXInferenceEngineEvent,
    to continuation: AsyncThrowingStream<MLXInferenceEngineEvent, any Error>.Continuation
  ) throws {
    switch continuation.yield(event) {
    case .enqueued:
      return
    case .dropped:
      throw MLXLocalInferenceProviderError.consumerTooSlow
    case .terminated:
      throw CancellationError()
    @unknown default:
      throw MLXLocalInferenceProviderError.generationFailed
    }
  }
}
