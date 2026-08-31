import HexCore

extension OpenAIResponsesProvider {
  func ensureResponseIdentifierTrackingAvailable() throws {
    guard !responseIdentifierTrackingExhausted else {
      throw OpenAIResponsesProviderError.continuationStateLimitExceeded
    }
  }

  func reserveResponseIdentifier(_ identifier: String) throws {
    try ensureResponseIdentifierTrackingAvailable()
    guard !issuedResponseIDs.contains(identifier) else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    let (projectedBytes, byteOverflow) = issuedResponseIDBytes.addingReportingOverflow(
      identifier.utf8.count
    )
    guard
      issuedResponseIDs.count < configuration.maximumIssuedResponseIDs,
      !byteOverflow,
      projectedBytes <= configuration.maximumIssuedResponseIDBytes
    else {
      responseIdentifierTrackingExhausted = true
      throw OpenAIResponsesProviderError.continuationStateLimitExceeded
    }
    issuedResponseIDs.insert(identifier)
    issuedResponseIDBytes = projectedBytes
  }

  func prepareContinuationCommit(
    request: InferenceRequest,
    plan: OpenAIResponsesRequestPlan,
    result: OpenAIResponsesStreamResult
  ) throws -> OpenAIContinuationCommit {
    guard issuedResponseIDs.contains(result.responseID) else {
      throw OpenAIResponsesProviderError.malformedStream
    }

    switch configuration.privacyMode {
    case .serverManagedContinuation:
      let state = try makeServerState(request: request, plan: plan, result: result)
      return OpenAIContinuationCommit(
        localState: nil,
        localEvictions: [],
        serverState: state,
        serverEvictions: try serverEvictions(for: state)
      )
    case .localEphemeralReplay:
      guard result.stopReason == .toolCalls else {
        return OpenAIContinuationCommit(
          localState: nil,
          localEvictions: [],
          serverState: nil,
          serverEvictions: []
        )
      }
      let state = try makeLocalState(request: request, plan: plan, result: result)
      return OpenAIContinuationCommit(
        localState: state,
        localEvictions: try localEvictions(for: state),
        serverState: nil,
        serverEvictions: []
      )
    }
  }

  func installContinuationCommit(_ commit: OpenAIContinuationCommit) {
    for identifier in commit.localEvictions {
      removeLocalState(identifier)
    }
    if let state = commit.localState {
      localStates[state.responseID] = state
      localStateOrder.append(state.responseID)
      localStateBytes += state.encodedByteCount
    }

    for identifier in commit.serverEvictions {
      removeServerState(identifier)
    }
    if let state = commit.serverState {
      serverStates[state.responseID] = state
      serverStateOrder.append(state.responseID)
      serverStateBytes += state.encodedByteCount
    }
  }

  func removeLocalState(_ identifier: String) {
    if let state = localStates.removeValue(forKey: identifier) {
      localStateBytes -= state.encodedByteCount
    }
    localStateOrder.removeAll(where: { $0 == identifier })
  }

  func removeServerState(_ identifier: String) {
    if let state = serverStates.removeValue(forKey: identifier) {
      serverStateBytes -= state.encodedByteCount
    }
    serverStateOrder.removeAll(where: { $0 == identifier })
  }

  private func makeLocalState(
    request: InferenceRequest,
    plan: OpenAIResponsesRequestPlan,
    result: OpenAIResponsesStreamResult
  ) throws -> OpenAILocalContinuationState {
    guard
      localStates[result.responseID] == nil,
      result.responseID != plan.priorLocalState?.responseID
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }

    let baseMessageCount = plan.priorLocalState?.baseMessageCount ?? plan.currentMessageIDs.count
    var replaySegments = plan.priorLocalState?.replaySegments ?? []
    guard replaySegments.count < configuration.maximumReplaySegments else {
      throw OpenAIResponsesProviderError.localStateLimitExceeded
    }
    replaySegments.append(
      OpenAILocalReplaySegment(
        afterMessageCount: plan.currentMessageIDs.count,
        outputItems: result.outputItems,
        encodedByteCount: result.encodedOutputBytes
      )
    )

    var outputBytes = 0
    for segment in replaySegments {
      let (withSegment, overflowed) = outputBytes.addingReportingOverflow(
        segment.encodedByteCount + 16
      )
      guard !overflowed else {
        throw OpenAIResponsesProviderError.localStateLimitExceeded
      }
      outputBytes = withSegment
    }
    let stateBytes = try measuredStateBytes(
      responseID: result.responseID,
      modelID: request.modelID,
      messageCount: plan.currentMessageIDs.count,
      outputBytes: outputBytes,
      maximum: configuration.maximumLocalStateBytes,
      error: .localStateLimitExceeded
    )
    guard plan.currentMessageIDs.count == plan.currentMessageFingerprints.count else {
      throw OpenAIResponsesProviderError.localStateLimitExceeded
    }

    return OpenAILocalContinuationState(
      responseID: result.responseID,
      modelID: request.modelID,
      baseMessageCount: baseMessageCount,
      knownMessageIDs: plan.currentMessageIDs,
      knownMessageFingerprints: plan.currentMessageFingerprints,
      replaySegments: replaySegments,
      encodedByteCount: stateBytes
    )
  }

  private func makeServerState(
    request: InferenceRequest,
    plan: OpenAIResponsesRequestPlan,
    result: OpenAIResponsesStreamResult
  ) throws -> OpenAIServerContinuationState {
    guard
      serverStates[result.responseID] == nil,
      result.responseID != plan.priorServerState?.responseID,
      plan.currentMessageIDs.count == plan.currentMessageFingerprints.count
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    let stateBytes = try measuredStateBytes(
      responseID: result.responseID,
      modelID: request.modelID,
      messageCount: plan.currentMessageIDs.count,
      outputBytes: result.encodedOutputBytes,
      maximum: configuration.maximumServerStateBytes,
      error: .continuationStateLimitExceeded
    )
    return OpenAIServerContinuationState(
      responseID: result.responseID,
      modelID: request.modelID,
      knownMessageIDs: plan.currentMessageIDs,
      knownMessageFingerprints: plan.currentMessageFingerprints,
      outputItems: result.outputItems,
      encodedByteCount: stateBytes
    )
  }

  private func measuredStateBytes(
    responseID: String,
    modelID: ModelID,
    messageCount: Int,
    outputBytes: Int,
    maximum: Int,
    error: OpenAIResponsesProviderError
  ) throws -> Int {
    let base = responseID.utf8.count + modelID.rawValue.utf8.count + 64
    let (messageBytes, messageOverflow) = messageCount.multipliedReportingOverflow(by: 64)
    let (withMessages, firstOverflow) = base.addingReportingOverflow(messageBytes)
    let (total, secondOverflow) = withMessages.addingReportingOverflow(outputBytes)
    guard
      !messageOverflow,
      !firstOverflow,
      !secondOverflow,
      total <= maximum
    else {
      throw error
    }
    return total
  }

  private func localEvictions(for state: OpenAILocalContinuationState) throws -> [String] {
    var projectedCount = localStates.count + 1
    var projectedBytes = localStateBytes + state.encodedByteCount
    var evictions: [String] = []
    for identifier in localStateOrder {
      guard
        projectedCount > configuration.maximumLocalStates
          || projectedBytes > configuration.maximumLocalCacheBytes
      else {
        break
      }
      guard let candidate = localStates[identifier] else { continue }
      evictions.append(identifier)
      projectedCount -= 1
      projectedBytes -= candidate.encodedByteCount
    }
    guard
      projectedCount <= configuration.maximumLocalStates,
      projectedBytes <= configuration.maximumLocalCacheBytes
    else {
      throw OpenAIResponsesProviderError.localStateLimitExceeded
    }
    return evictions
  }

  private func serverEvictions(for state: OpenAIServerContinuationState) throws -> [String] {
    var projectedCount = serverStates.count + 1
    var projectedBytes = serverStateBytes + state.encodedByteCount
    var evictions: [String] = []
    for identifier in serverStateOrder {
      guard
        projectedCount > configuration.maximumServerStates
          || projectedBytes > configuration.maximumServerCacheBytes
      else {
        break
      }
      guard let candidate = serverStates[identifier] else { continue }
      evictions.append(identifier)
      projectedCount -= 1
      projectedBytes -= candidate.encodedByteCount
    }
    guard
      projectedCount <= configuration.maximumServerStates,
      projectedBytes <= configuration.maximumServerCacheBytes
    else {
      throw OpenAIResponsesProviderError.continuationStateLimitExceeded
    }
    return evictions
  }
}
