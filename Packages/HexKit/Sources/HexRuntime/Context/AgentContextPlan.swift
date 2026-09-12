/// A proposal only: no messages are rewritten or omitted, and no summary is fabricated. Before
/// applying a compaction proposal, the caller must produce/validate a summary, account for its
/// message envelope, preserve provenance, and replan the resulting fresh inference request.
public enum AgentContextPlan: Equatable, Sendable {
  case fits(AgentContextBudget)
  /// Ranges index only the original `messages`, never the separately pinned messages. The entire
  /// summary message (including its framing) must fit maximumSummaryTokens; this isn't an LLM
  /// max-output setting. The retained range includes the latest user and latest closed exchange.
  case requiresCompaction(
    AgentContextBudget,
    prefixRange: Range<Int>,
    retainedRange: Range<Int>,
    maximumSummaryTokens: Int
  )
  case protectedOverflow(AgentContextBudget, reason: AgentContextPlanProtectionReason)
  case unestimated(AgentContextPlanUnestimatedReason)
}
