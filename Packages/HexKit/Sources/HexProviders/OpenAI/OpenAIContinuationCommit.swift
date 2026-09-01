struct OpenAIContinuationCommit: Sendable {
  let localState: OpenAILocalContinuationState?
  let localEvictions: [String]
  let serverState: OpenAIServerContinuationState?
  let serverEvictions: [String]
}
