import HexCore
import HexProviders
import MLXLMCommon

struct MLXSwiftInferenceEngine: MLXInferenceEngine, Sendable {
  private let model: ModelContainer
  private let modelID: ModelID
  private let defaultMaximumOutputTokens: Int
  private let maximumBufferedEvents: Int

  init(
    model: ModelContainer,
    modelID: ModelID,
    defaultMaximumOutputTokens: Int,
    maximumBufferedEvents: Int = 64
  ) {
    self.model = model
    self.modelID = modelID
    self.defaultMaximumOutputTokens = defaultMaximumOutputTokens
    self.maximumBufferedEvents = maximumBufferedEvents
  }

  func stream(
    _ request: InferenceRequest
  ) async throws -> AsyncThrowingStream<MLXInferenceEngineEvent, any Error> {
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
        let generations = session.streamDetails(to: messages)
        var completed = false

        for try await generation in generations {
          try Task.checkCancellation()
          guard !completed else {
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
            try Self.yield(
              .completed(
                usage: InferenceUsage(
                  inputTokens: inputTokens,
                  outputTokens: outputTokens
                ),
                stopReason: stopReason
              ),
              to: continuation
            )
            completed = true
          }
        }
        guard completed else {
          throw MLXLocalInferenceProviderError.incompleteStream
        }
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
    return stream
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
