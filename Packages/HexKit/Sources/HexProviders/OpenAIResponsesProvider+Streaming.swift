import Foundation
import HexCore

extension OpenAIResponsesProvider {
  public func stream(
    _ request: InferenceRequest
  ) async throws -> AsyncThrowingStream<InferenceStreamEvent, any Error> {
    try Task.checkCancellation()

    let continuationKey = request.previousProviderResponseID
    let localState: OpenAILocalContinuationState?
    if configuration.privacyMode == .localEphemeralReplay, let continuationKey {
      guard
        !localStatesInUse.contains(continuationKey),
        let state = localStates[continuationKey]
      else {
        throw OpenAIResponsesProviderError.missingLocalContinuation
      }
      guard state.modelID == request.modelID else {
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }
      localStatesInUse.insert(continuationKey)
      localState = state
    } else {
      localState = nil
    }

    let plan: OpenAIResponsesRequestPlan
    do {
      plan = try OpenAIResponsesRequestBuilder(configuration: configuration).build(
        request,
        localState: localState
      )
    } catch {
      releaseLocalState(continuationKey)
      throw error
    }

    let apiKey: String
    do {
      apiKey = try await credentialProvider.apiKey()
      try Task.checkCancellation()
    } catch is CancellationError {
      releaseLocalState(continuationKey)
      throw CancellationError()
    } catch {
      releaseLocalState(continuationKey)
      if Task.isCancelled {
        throw CancellationError()
      }
      throw OpenAIResponsesProviderError.credentialUnavailable
    }

    guard isValidAPIKey(apiKey) else {
      releaseLocalState(continuationKey)
      throw OpenAIResponsesProviderError.credentialUnavailable
    }

    var urlRequest = URLRequest(url: configuration.endpoint)
    urlRequest.httpMethod = "POST"
    urlRequest.timeoutInterval = configuration.requestTimeout
    urlRequest.httpBody = plan.body
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    let response: OpenAIResponsesTransportResponse
    do {
      response = try await transport.send(urlRequest)
      try Task.checkCancellation()
    } catch is CancellationError {
      releaseLocalState(continuationKey)
      throw CancellationError()
    } catch {
      releaseLocalState(continuationKey)
      if Task.isCancelled {
        throw CancellationError()
      }
      throw OpenAIResponsesProviderError.transportFailed
    }

    guard (200...299).contains(response.statusCode) else {
      releaseLocalState(continuationKey)
      throw OpenAIResponsesProviderError.httpFailure(statusCode: response.statusCode)
    }
    let mediaType = response.contentType?
      .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
      .first?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard mediaType == "text/event-stream" else {
      releaseLocalState(continuationKey)
      throw OpenAIResponsesProviderError.invalidContentType
    }

    let bufferingLimit = min(configuration.maximumStreamEvents, 1_024)
    return AsyncThrowingStream<InferenceStreamEvent, any Error>(
      bufferingPolicy: .bufferingOldest(bufferingLimit)
    ) { continuation in
      let producer = Task {
        await self.consume(
          response.body,
          request: request,
          plan: plan,
          continuationKey: continuationKey,
          continuation: continuation
        )
      }
      continuation.onTermination = { @Sendable _ in
        producer.cancel()
      }
    }
  }

  func consume(
    _ body: AsyncThrowingStream<Data, any Error>,
    request: InferenceRequest,
    plan: OpenAIResponsesRequestPlan,
    continuationKey: String?,
    continuation: AsyncThrowingStream<InferenceStreamEvent, any Error>.Continuation
  ) async {
    defer {
      releaseLocalState(continuationKey)
    }

    do {
      var parser = ServerSentEventParser(configuration: configuration)
      var processor = OpenAIResponsesStreamProcessor(configuration: configuration)
      var pendingTerminal: OpenAIResponsesProcessedEvent?

      for try await chunk in body {
        try Task.checkCancellation()
        let serverEvents = try parser.feed(chunk)
        for serverEvent in serverEvents {
          try Task.checkCancellation()
          let processed = try processor.process(serverEvent)
          if processed.terminalResult != nil {
            guard pendingTerminal == nil else {
              throw OpenAIResponsesProviderError.malformedStream
            }
            pendingTerminal = processed
          } else {
            for event in processed.events {
              try yield(event, to: continuation)
            }
          }
        }
      }

      try Task.checkCancellation()

      for serverEvent in try parser.finish() {
        try Task.checkCancellation()
        let processed = try processor.process(serverEvent)
        if processed.terminalResult != nil {
          guard pendingTerminal == nil else {
            throw OpenAIResponsesProviderError.malformedStream
          }
          pendingTerminal = processed
        } else {
          for event in processed.events {
            try yield(event, to: continuation)
          }
        }
      }
      try processor.finish()
      guard let pendingTerminal, let result = pendingTerminal.terminalResult else {
        throw OpenAIResponsesProviderError.truncatedStream
      }
      try Task.checkCancellation()
      try commitLocalState(
        request: request,
        plan: plan,
        result: result
      )
      for event in pendingTerminal.events {
        try yield(event, to: continuation)
      }
      continuation.finish()
    } catch is CancellationError {
      continuation.finish(throwing: CancellationError())
    } catch let error as OpenAIResponsesProviderError {
      continuation.finish(throwing: error)
    } catch {
      if Task.isCancelled {
        continuation.finish(throwing: CancellationError())
      } else {
        continuation.finish(throwing: OpenAIResponsesProviderError.transportFailed)
      }
    }
  }

  func yield(
    _ event: InferenceStreamEvent,
    to continuation: AsyncThrowingStream<InferenceStreamEvent, any Error>.Continuation
  ) throws {
    switch continuation.yield(event) {
    case .enqueued:
      return
    case .dropped:
      throw OpenAIResponsesProviderError.streamLimitExceeded
    case .terminated:
      throw CancellationError()
    @unknown default:
      throw OpenAIResponsesProviderError.transportFailed
    }
  }

  func isValidAPIKey(_ value: String) -> Bool {
    let bytes = value.utf8
    guard !bytes.isEmpty, bytes.count <= 4_096 else { return false }
    return bytes.allSatisfy { byte in
      byte >= 0x21 && byte <= 0x7E
    }
  }
}
