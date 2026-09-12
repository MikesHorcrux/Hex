import Dispatch
import HexCore

struct ToolAuthorizationLedgerEntry: Sendable {
  let call: ToolCall
  let expiresAt: UInt64
}
