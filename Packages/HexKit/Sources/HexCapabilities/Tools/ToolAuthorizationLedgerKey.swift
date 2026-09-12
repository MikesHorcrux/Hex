import Dispatch
import HexCore

struct ToolAuthorizationLedgerKey: Hashable, Sendable {
  let runID: AgentRunID
  let toolCallID: ToolCallID
}
