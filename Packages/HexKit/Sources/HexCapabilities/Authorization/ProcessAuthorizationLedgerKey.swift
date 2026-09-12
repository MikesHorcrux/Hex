import Dispatch
import HexCore

struct ProcessAuthorizationLedgerKey: Hashable, Sendable {
  let runID: AgentRunID
  let toolCallID: ToolCallID
}
