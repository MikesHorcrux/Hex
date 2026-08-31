import HexCore

extension MLXLocalInferenceProvider {
  public func stream(
    _ request: InferenceRequest
  ) async throws -> InferenceStream {
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

    let engineRun: MLXInferenceEngineRun
    do {
      engineRun = try await engine.start(request)
    } catch is CancellationError {
      finishRequest(request.id)
      throw CancellationError()
    } catch {
      finishRequest(request.id)
      throw MLXLocalInferenceProviderError.generationFailed
    }
    if Task.isCancelled {
      engineRun.cancel()
      await engineRun.waitForTermination()
      finishRequest(request.id)
      throw CancellationError()
    }

    return outputStream(
      for: request,
      model: model,
      engineRun: engineRun
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
    engineRun: MLXInferenceEngineRun
  ) -> InferenceStream {
    let (stream, continuation) = AsyncThrowingStream.makeStream(
      of: InferenceStreamEvent.self,
      throwing: (any Error).self,
      bufferingPolicy: .bufferingOldest(configuration.maximumBufferedEvents)
    )
    let producer = Task {
      do {
        try await withTaskCancellationHandler {
          try Task.checkCancellation()
          try Self.yield(.started(providerResponseID: nil), to: continuation)
          var pendingTerminal: (InferenceUsage, InferenceStopReason)?
          var toolCallIDs = Set<ToolCallID>()
          var toolCallCount = 0
          var textBytes = 0
          var eventCount = 0
          var remainingGeneratedBytes = MLXRequestContentValidator.maximumRequestBytes
          var remainingGeneratedNodes = MLXRequestContentValidator.maximumJSONNodes

          for try await event in engineRun.events {
            try Task.checkCancellation()
            guard pendingTerminal == nil else {
              throw MLXLocalInferenceProviderError.invalidStream
            }
            eventCount += 1
            guard eventCount <= 65_536 else {
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
                Self.isValidGeneratedToolCall(
                  call,
                  request: request,
                  remainingBytes: &remainingGeneratedBytes,
                  remainingNodes: &remainingGeneratedNodes
                ),
                toolCallIDs.insert(call.id).inserted
              else {
                throw MLXLocalInferenceProviderError.invalidStream
              }
              toolCallCount += 1
              guard
                toolCallCount <= 4_096,
                model.supportsParallelToolCalling || toolCallCount == 1
              else {
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
              guard
                Self.isValidUsage(
                  usage,
                  request: request,
                  model: model,
                  hasGeneratedOutput: textBytes > 0 || toolCallCount > 0
                ),
                let stopReason = Self.validatedStopReason(
                  engineStopReason,
                  textBytes: textBytes,
                  toolCallCount: toolCallCount
                )
              else {
                throw MLXLocalInferenceProviderError.invalidStream
              }
              pendingTerminal = (usage, stopReason)
            }
          }
          await engineRun.waitForTermination()
          try Task.checkCancellation()
          guard let (usage, stopReason) = pendingTerminal else {
            throw MLXLocalInferenceProviderError.incompleteStream
          }
          try Self.yield(.usage(usage), to: continuation)
          try Self.yield(.completed(stopReason), to: continuation)
          finishRequest(request.id)
          continuation.finish()
        } onCancel: {
          engineRun.cancel()
        }
      } catch is CancellationError {
        engineRun.cancel()
        continuation.finish(throwing: CancellationError())
        await engineRun.waitForTermination()
        finishRequest(request.id)
      } catch let error as MLXLocalInferenceProviderError {
        engineRun.cancel()
        continuation.finish(throwing: error)
        await engineRun.waitForTermination()
        finishRequest(request.id)
      } catch {
        engineRun.cancel()
        continuation.finish(throwing: MLXLocalInferenceProviderError.generationFailed)
        await engineRun.waitForTermination()
        finishRequest(request.id)
      }
    }
    return InferenceStream(
      events: stream,
      onCancellation: {
        producer.cancel()
      },
      waitForTermination: {
        await producer.value
      }
    )
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
