import HexCore
import HexProviders
import MLXLMCommon

struct MLXSwiftInferenceEngine: MLXInferenceEngine, Sendable {
  private let modelID: ModelID
  private let defaultMaximumOutputTokens: Int
  private let maximumContextTokens: Int
  private let supportsToolCalling: Bool
  private let maximumBufferedEvents: Int
  private let artifactSnapshot: MLXModelArtifactSnapshot?
  private let generationRuns:
    @Sendable (InferenceRequest, Int, Int) async throws -> MLXSwiftGenerationRun

  init(
    model: ModelContainer,
    modelID: ModelID,
    defaultMaximumOutputTokens: Int,
    maximumContextTokens: Int,
    supportsToolCalling: Bool = false,
    artifactSnapshot: MLXModelArtifactSnapshot,
    maximumBufferedEvents: Int = 64
  ) {
    self.modelID = modelID
    self.defaultMaximumOutputTokens = defaultMaximumOutputTokens
    self.maximumContextTokens = maximumContextTokens
    self.supportsToolCalling = supportsToolCalling
    self.artifactSnapshot = artifactSnapshot
    self.maximumBufferedEvents = maximumBufferedEvents
    generationRuns = { request, maximumOutputTokens, maximumContextTokens in
      try artifactSnapshot.validateBoundPath()
      let run = try await Self.makeGenerationRun(
        model: model,
        request: request,
        maximumOutputTokens: maximumOutputTokens,
        maximumContextTokens: maximumContextTokens
      )
      try artifactSnapshot.validateBoundPath()
      return run
    }
  }

  init(
    modelID: ModelID,
    defaultMaximumOutputTokens: Int,
    maximumContextTokens: Int = 32_768,
    supportsToolCalling: Bool = false,
    maximumBufferedEvents: Int = 64,
    artifactSnapshot: MLXModelArtifactSnapshot? = nil,
    generationRuns:
      @escaping @Sendable (
        InferenceRequest,
        Int,
        Int
      ) async throws -> MLXSwiftGenerationRun
  ) {
    self.modelID = modelID
    self.defaultMaximumOutputTokens = defaultMaximumOutputTokens
    self.maximumContextTokens = maximumContextTokens
    self.supportsToolCalling = supportsToolCalling
    self.maximumBufferedEvents = maximumBufferedEvents
    self.artifactSnapshot = artifactSnapshot
    self.generationRuns = generationRuns
  }

  func start(
    _ request: InferenceRequest
  ) async throws -> MLXInferenceEngineRun {
    try Task.checkCancellation()
    try MLXInferenceRequestAdmission.validate(
      request,
      modelID: modelID,
      maximumOutputTokens: defaultMaximumOutputTokens,
      maximumContextTokens: maximumContextTokens,
      supportsToolCalling: supportsToolCalling
    )
    try artifactSnapshot?.validateBoundPath()
    let maximumOutputTokens = request.options.maxOutputTokens ?? defaultMaximumOutputTokens

    let (stream, continuation) = AsyncThrowingStream.makeStream(
      of: MLXInferenceEngineEvent.self,
      throwing: (any Error).self,
      bufferingPolicy: .bufferingOldest(maximumBufferedEvents)
    )
    let producer = Task {
      var generationRun: MLXSwiftGenerationRun?
      do {
        try Task.checkCancellation()
        let run = try await generationRuns(
          request,
          maximumOutputTokens,
          maximumContextTokens
        )
        generationRun = run
        try Task.checkCancellation()
        var pendingTerminal: (InferenceUsage, InferenceStopReason)?

        try await withTaskCancellationHandler {
          for await generation in run.events {
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
                let outputTokens = UInt64(exactly: info.generationTokenCount),
                inputTokens > 0
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
          await run.waitForTermination()
          try artifactSnapshot?.validateBoundPath()
          try Task.checkCancellation()
        } onCancel: {
          run.cancel()
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
        if let generationRun {
          generationRun.cancel()
          await generationRun.waitForTermination()
        }
      } catch let error as MLXLocalInferenceProviderError {
        continuation.finish(throwing: error)
        if let generationRun {
          generationRun.cancel()
          await generationRun.waitForTermination()
        }
      } catch {
        continuation.finish(throwing: MLXLocalInferenceProviderError.generationFailed)
        if let generationRun {
          generationRun.cancel()
          await generationRun.waitForTermination()
        }
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

  static func validateContext(
    promptTokenCount: Int,
    maximumOutputTokens: Int,
    maximumContextTokens: Int
  ) throws {
    guard
      promptTokenCount > 0,
      maximumOutputTokens > 0,
      maximumOutputTokens <= maximumContextTokens,
      promptTokenCount <= maximumContextTokens - maximumOutputTokens
    else {
      throw MLXLocalInferenceProviderError.invalidRequest
    }
  }

  private static func makeGenerationRun(
    model: ModelContainer,
    request: InferenceRequest,
    maximumOutputTokens: Int,
    maximumContextTokens: Int
  ) async throws -> MLXSwiftGenerationRun {
    try Task.checkCancellation()
    let messages = try MLXSwiftRequestMapper.messages(for: request)
    let tools = try MLXSwiftRequestMapper.toolSpecifications(for: request)
    let parameters = GenerateParameters(
      maxTokens: maximumOutputTokens,
      temperature: Float(request.options.temperature ?? 0.6)
    )
    let input = try await model.prepare(
      input: UserInput(chat: messages, tools: tools)
    )
    try Task.checkCancellation()
    let promptTokenCount = input.text.tokens.size
    try validateContext(
      promptTokenCount: promptTokenCount,
      maximumOutputTokens: maximumOutputTokens,
      maximumContextTokens: maximumContextTokens
    )

    return try await model.perform(nonSendable: input) { context, input in
      try Task.checkCancellation()
      let iterator = try TokenIterator(
        input: input,
        model: context.model,
        parameters: parameters
      )
      let (events, generationTask) = MLXLMCommon.generateTask(
        promptTokenCount: promptTokenCount,
        modelConfiguration: context.configuration,
        tokenizer: context.tokenizer,
        iterator: iterator,
        tools: tools
      )
      return MLXSwiftGenerationRun(
        events: events,
        cancel: {
          generationTask.cancel()
        },
        waitForTermination: {
          await generationTask.value
        }
      )
    }
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
