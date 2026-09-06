/// Summarization produces a candidate only. The owner must validate its provenance, replan the
/// fully wrapped checkpoint, and commit it atomically before replacing any inference context.
public protocol AgentContextSummarizing: Sendable {
  func summarize(_ request: AgentContextSummaryRequest) async throws -> AgentContextSummaryResult
}
