import Dispatch
import Foundation
import HexCapabilities
import HexCore
import HexPersonality

struct PersonalMemoryAuthorizationLedgerKey: Hashable, Sendable {
  let runID: AgentRunID
  let toolCallID: ToolCallID
}
