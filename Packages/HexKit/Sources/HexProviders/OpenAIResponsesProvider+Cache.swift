import HexCore

extension OpenAIResponsesProvider {
  func commitLocalState(
    request: InferenceRequest,
    plan: OpenAIResponsesRequestPlan,
    result: OpenAIResponsesStreamResult
  ) throws {
    guard configuration.privacyMode == .localEphemeralReplay else { return }
    guard
      result.responseID != plan.priorLocalState?.responseID,
      localStates[result.responseID] == nil
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }

    if result.stopReason != .toolCalls {
      if let priorResponseID = plan.priorLocalState?.responseID {
        removeLocalState(priorResponseID)
      }
      return
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

    var stateBytes = result.responseID.utf8.count + request.modelID.rawValue.utf8.count + 64
    guard plan.currentMessageIDs.count == plan.currentMessageFingerprints.count else {
      throw OpenAIResponsesProviderError.localStateLimitExceeded
    }
    for _ in plan.currentMessageIDs {
      let (withIdentifier, identifierOverflow) = stateBytes.addingReportingOverflow(64)
      guard
        !identifierOverflow,
        withIdentifier <= configuration.maximumLocalStateBytes
      else {
        throw OpenAIResponsesProviderError.localStateLimitExceeded
      }
      stateBytes = withIdentifier
    }
    for segment in replaySegments {
      let (withSegment, segmentOverflow) = stateBytes.addingReportingOverflow(
        segment.encodedByteCount + 16
      )
      guard !segmentOverflow, withSegment <= configuration.maximumLocalStateBytes else {
        throw OpenAIResponsesProviderError.localStateLimitExceeded
      }
      stateBytes = withSegment
    }

    guard
      stateBytes <= configuration.maximumLocalStateBytes
    else {
      throw OpenAIResponsesProviderError.localStateLimitExceeded
    }

    let state = OpenAILocalContinuationState(
      responseID: result.responseID,
      modelID: request.modelID,
      baseMessageCount: baseMessageCount,
      knownMessageIDs: plan.currentMessageIDs,
      knownMessageFingerprints: plan.currentMessageFingerprints,
      replaySegments: replaySegments,
      encodedByteCount: stateBytes
    )

    if let priorResponseID = plan.priorLocalState?.responseID {
      removeLocalState(priorResponseID)
    }
    removeLocalState(result.responseID)
    localStates[result.responseID] = state
    localStateOrder.append(result.responseID)
    localStateBytes += state.encodedByteCount

    try evictLocalStatesIfNeeded(protecting: result.responseID)
  }

  func evictLocalStatesIfNeeded(protecting protectedID: String) throws {
    while localStates.count > configuration.maximumLocalStates
      || localStateBytes > configuration.maximumLocalCacheBytes
    {
      guard
        let candidate = localStateOrder.first(where: { identifier in
          identifier != protectedID && !localStatesInUse.contains(identifier)
        })
      else {
        removeLocalState(protectedID)
        throw OpenAIResponsesProviderError.localStateLimitExceeded
      }
      removeLocalState(candidate)
    }
  }

  func releaseLocalState(_ identifier: String?) {
    guard configuration.privacyMode == .localEphemeralReplay, let identifier else { return }
    localStatesInUse.remove(identifier)
  }

  func removeLocalState(_ identifier: String) {
    if let state = localStates.removeValue(forKey: identifier) {
      localStateBytes -= state.encodedByteCount
    }
    localStateOrder.removeAll(where: { $0 == identifier })
  }
}
