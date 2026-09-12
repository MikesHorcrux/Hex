/// Only returned after every source exchange has contributed to a complete validated checkpoint.
/// Reported tokens are actual provider-reported totals, not estimates; omitted usage contributes
/// zero and must not be presented as proof that inference was free.
public struct AgentContextSummaryResult: Equatable, Sendable {
  public let text: String
  public let reportedTokens: UInt64
  public let inferenceCalls: Int

  public init(text: String, reportedTokens: UInt64, inferenceCalls: Int) {
    self.text = text
    self.reportedTokens = reportedTokens
    self.inferenceCalls = inferenceCalls
  }
}
