import HexCore

struct AgentContextPlannerExchangeLayout: Sendable {
  let closedExchanges: [Range<Int>]
  let protectedStart: Int
  let latestUserIndex: Int
  let hasOpenToolChain: Bool
}
