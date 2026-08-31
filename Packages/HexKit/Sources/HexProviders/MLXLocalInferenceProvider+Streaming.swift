import HexCore

extension MLXLocalInferenceProvider {
  public func stream(
    _ request: InferenceRequest
  ) async throws -> AsyncThrowingStream<InferenceStreamEvent, any Error> {
    try Task.checkCancellation()
    let model = try validatedModel(for: request)
    guard activeRequestID == nil else {
      throw MLXLocalInferenceProviderError.busy
    }
    activeRequestID = request.id

    let engine: any MLXInferenceEngine
    do {
      engine = try await loadEngine(for: model)
      try Task.checkCancellation()
    } catch is CancellationError {
      finishRequest(request.id)
      throw CancellationError()
    } catch {
      finishRequest(request.id)
      throw MLXLocalInferenceProviderError.modelLoadFailed
    }

    let engineStream: AsyncThrowingStream<MLXInferenceEngineEvent, any Error>
    do {
      engineStream = try await engine.stream(request)
      try Task.checkCancellation()
    } catch is CancellationError {
      finishRequest(request.id)
      throw CancellationError()
    } catch {
      finishRequest(request.id)
      throw MLXLocalInferenceProviderError.generationFailed
    }

    return outputStream(
      for: request,
      model: model,
      engineStream: engineStream
    )
  }

  private func loadEngine(
    for model: MLXLocalModelConfiguration
  ) async throws -> any MLXInferenceEngine {
    if cachedModelID == model.modelID, let cachedEngine {
      return cachedEngine
    }
    cachedEngine = nil
    cachedModelID = nil
    let loaded = try await engineLoader.loadModel(model)
    try Task.checkCancellation()
    cachedEngine = loaded
    cachedModelID = model.modelID
    return loaded
  }

  private func outputStream(
    for request: InferenceRequest,
    model: MLXLocalModelConfiguration,
    engineStream: AsyncThrowingStream<MLXInferenceEngineEvent, any Error>
  ) -> AsyncThrowingStream<InferenceStreamEvent, any Error> {
    let (stream, continuation) = AsyncThrowingStream.makeStream(
      of: InferenceStreamEvent.self,
      throwing: (any Error).self,
      bufferingPolicy: .bufferingOldest(configuration.maximumBufferedEvents)
    )
    let producer = Task {
      do {
        try Self.yield(.started(providerResponseID: nil), to: continuation)
        var completed = false
        var toolCallIDs = Set<ToolCallID>()
        var toolCallCount = 0
        var textBytes = 0
        var eventCount = 0

        for try await event in engineStream {
          try Task.checkCancellation()
          guard !completed else {
            throw MLXLocalInferenceProviderError.invalidStream
          }
          eventCount += 1
          guard eventCount <= 1_000_000 else {
            throw MLXLocalInferenceProviderError.invalidStream
          }
          switch event {
          case .textDelta(let delta):
            guard !delta.isEmpty, !delta.contains("\0") else {
              throw MLXLocalInferenceProviderError.invalidStream
            }
            let (candidateBytes, overflowed) = textBytes.addingReportingOverflow(
              delta.utf8.count
            )
            guard !overflowed, candidateBytes <= 16 * 1_024 * 1_024 else {
              throw MLXLocalInferenceProviderError.invalidStream
            }
            textBytes = candidateBytes
            try Self.yield(.textDelta(delta), to: continuation)

          case .toolCall(let call):
            guard
              Self.isValidGeneratedToolCall(call, request: request),
              toolCallIDs.insert(call.id).inserted
            else {
              throw MLXLocalInferenceProviderError.invalidStream
            }
            toolCallCount += 1
            guard model.supportsParallelToolCalling || toolCallCount == 1 else {
              throw MLXLocalInferenceProviderError.parallelToolCallsUnsupported
            }
            try Self.yield(.toolCall(call), to: continuation)

          case .completed(let usage, let engineStopReason):
            switch request.toolChoice {
            case .required, .named:
              guard toolCallCount > 0 else {
                throw MLXLocalInferenceProviderError.invalidStream
              }
            case .automatic, .none:
              break
            }
            guard engineStopReason != .toolCalls || toolCallCount > 0 else {
              throw MLXLocalInferenceProviderError.invalidStream
            }
            let stopReason: InferenceStopReason
            if toolCallCount > 0, engineStopReason == .stop {
              stopReason = .toolCalls
            } else {
              stopReason = engineStopReason
            }
            try Self.yield(.usage(usage), to: continuation)
            try Self.yield(.completed(stopReason), to: continuation)
            completed = true
          }
        }
        guard completed else {
          throw MLXLocalInferenceProviderError.incompleteStream
        }
        finishRequest(request.id)
        continuation.finish()
      } catch is CancellationError {
        finishRequest(request.id)
        continuation.finish(throwing: CancellationError())
      } catch let error as MLXLocalInferenceProviderError {
        finishRequest(request.id)
        continuation.finish(throwing: error)
      } catch {
        finishRequest(request.id)
        continuation.finish(throwing: MLXLocalInferenceProviderError.generationFailed)
      }
    }
    continuation.onTermination = { @Sendable _ in
      producer.cancel()
    }
    return stream
  }

  private nonisolated static func yield(
    _ event: InferenceStreamEvent,
    to continuation: AsyncThrowingStream<InferenceStreamEvent, any Error>.Continuation
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

  private func finishRequest(_ requestID: InferenceRequestID) {
    if activeRequestID == requestID {
      activeRequestID = nil
    }
  }
}
