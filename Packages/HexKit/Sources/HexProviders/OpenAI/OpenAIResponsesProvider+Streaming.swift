import Foundation
import HexCore

extension OpenAIResponsesProvider {
  public func stream(
    _ request: InferenceRequest
  ) async throws -> InferenceStream {
    try Task.checkCancellation()
    try ensureResponseIdentifierTrackingAvailable()

    let continuationKey = request.previousProviderResponseID
    let serverState: OpenAIServerContinuationState?
    let localState: OpenAILocalContinuationState?
    switch configuration.privacyMode {
    case .serverManagedContinuation:
      localState = nil
      if let continuationKey {
        guard
          issuedResponseIDs.contains(continuationKey),
          let state = serverStates[continuationKey],
          state.modelID == request.modelID
        else {
          throw OpenAIResponsesProviderError.invalidRequest
        }
        serverState = state
      } else {
        serverState = nil
      }
    case .localEphemeralReplay:
      serverState = nil
      if let continuationKey {
        guard issuedResponseIDs.contains(continuationKey) else {
          throw OpenAIResponsesProviderError.missingLocalContinuation
        }
        guard let state = localStates[continuationKey] else {
          throw OpenAIResponsesProviderError.missingLocalContinuation
        }
        guard state.modelID == request.modelID else {
          throw OpenAIResponsesProviderError.localContinuationMismatch
        }
        localState = state
      } else {
        localState = nil
      }
    }

    let plan: OpenAIResponsesRequestPlan
    do {
      plan = try OpenAIResponsesRequestBuilder(configuration: configuration).build(
        request,
        serverState: serverState,
        localState: localState
      )
    } catch let error as OpenAIResponsesProviderError {
      if configuration.privacyMode == .serverManagedContinuation,
        request.previousProviderResponseID != nil
      {
        throw OpenAIResponsesProviderError.invalidRequest
      }
      throw error
    } catch {
      if configuration.privacyMode == .serverManagedContinuation,
        request.previousProviderResponseID != nil
      {
        throw OpenAIResponsesProviderError.invalidRequest
      }
      throw error
    }

    if let continuationKey {
      switch configuration.privacyMode {
      case .serverManagedContinuation:
        removeServerState(continuationKey)
      case .localEphemeralReplay:
        removeLocalState(continuationKey)
      }
    }

    let authorization: OpenAIResponsesAuthorization
    do {
      authorization = try await authorizationProvider.authorization()
      try Task.checkCancellation()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if Task.isCancelled {
        throw CancellationError()
      }
      throw OpenAIResponsesProviderError.credentialUnavailable
    }

    guard isValidBearerToken(authorization.bearerToken) else {
      throw OpenAIResponsesProviderError.credentialUnavailable
    }
    switch configuration.service {
    case .platformAPI:
      guard authorization.accountID == nil else {
        throw OpenAIResponsesProviderError.credentialUnavailable
      }
    case .chatGPTCodexSubscription:
      guard let accountID = authorization.accountID, isValidAccountID(accountID) else {
        throw OpenAIResponsesProviderError.credentialUnavailable
      }
    }

    var urlRequest = URLRequest(url: configuration.endpoint)
    urlRequest.httpMethod = "POST"
    urlRequest.timeoutInterval = configuration.requestTimeout
    urlRequest.httpBody = plan.body
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    urlRequest.setValue(
      "Bearer \(authorization.bearerToken)",
      forHTTPHeaderField: "Authorization"
    )
    urlRequest.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
    if configuration.service == .chatGPTCodexSubscription,
      let accountID = authorization.accountID
    {
      urlRequest.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
      urlRequest.setValue(configuration.originator, forHTTPHeaderField: "originator")
    }

    let response: OpenAIResponsesTransportResponse
    do {
      response = try await transport.send(urlRequest)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if Task.isCancelled {
        throw CancellationError()
      }
      throw OpenAIResponsesProviderError.transportFailed
    }
    if Task.isCancelled {
      await response.cancelAndWait()
      throw CancellationError()
    }

    guard (200...299).contains(response.statusCode) else {
      await response.cancelAndWait()
      throw OpenAIResponsesProviderError.httpFailure(statusCode: response.statusCode)
    }
    let mediaType = response.contentType?
      .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
      .first?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard mediaType == "text/event-stream" else {
      await response.cancelAndWait()
      throw OpenAIResponsesProviderError.invalidContentType
    }

    let (bufferingLimit, bufferingOverflow) = configuration.maximumStreamEvents
      .addingReportingOverflow(configuration.maximumOutputItems + 4)
    guard !bufferingOverflow else {
      await response.cancelAndWait()
      throw OpenAIResponsesProviderError.invalidConfiguration
    }
    let (events, continuation) = AsyncThrowingStream.makeStream(
      of: InferenceStreamEvent.self,
      throwing: (any Error).self,
      bufferingPolicy: .bufferingOldest(bufferingLimit)
    )
    let producer = Task {
      await self.consume(
        response.body,
        request: request,
        plan: plan,
        continuation: continuation
      )
    }
    return InferenceStream(
      events: events,
      onCancellation: {
        producer.cancel()
        response.cancel()
      },
      waitForTermination: {
        await producer.value
        await response.cancelAndWait()
      }
    )
  }

  func consume(
    _ body: AsyncThrowingStream<Data, any Error>,
    request: InferenceRequest,
    plan: OpenAIResponsesRequestPlan,
    continuation: AsyncThrowingStream<InferenceStreamEvent, any Error>.Continuation
  ) async {
    do {
      var parser = ServerSentEventParser(configuration: configuration)
      var processor = OpenAIResponsesStreamProcessor(
        configuration: configuration,
        tools: request.tools,
        toolChoice: request.toolChoice,
        allowsParallelToolCalls: plan.allowsParallelToolCalls
      )
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
              try reserveIdentifierIfStarted(event)
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
            try reserveIdentifierIfStarted(event)
            try yield(event, to: continuation)
          }
        }
      }
      try processor.finish()
      guard let pendingTerminal, let result = pendingTerminal.terminalResult else {
        throw OpenAIResponsesProviderError.truncatedStream
      }
      try Task.checkCancellation()
      let commit = try prepareContinuationCommit(
        request: request,
        plan: plan,
        result: result
      )
      for event in pendingTerminal.events {
        try yield(event, to: continuation)
      }
      installContinuationCommit(commit)
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

  func reserveIdentifierIfStarted(_ event: InferenceStreamEvent) throws {
    guard case .started(let responseIdentifier) = event else { return }
    guard let identifier = responseIdentifier else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    try reserveResponseIdentifier(identifier)
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

  func isValidBearerToken(_ value: String) -> Bool {
    let bytes = value.utf8
    guard !bytes.isEmpty, bytes.count <= 32 * 1_024 else { return false }
    return bytes.allSatisfy { byte in
      byte >= 0x21 && byte <= 0x7E
    }
  }

  func isValidAccountID(_ value: String) -> Bool {
    let bytes = value.utf8
    guard !bytes.isEmpty, bytes.count <= 512 else { return false }
    return bytes.allSatisfy { byte in
      byte >= 0x21 && byte <= 0x7E
    }
  }
}
