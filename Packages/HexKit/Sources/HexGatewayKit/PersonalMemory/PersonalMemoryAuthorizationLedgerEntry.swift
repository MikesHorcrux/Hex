import Dispatch
import Foundation
import HexCapabilities
import HexCore
import HexPersonality

struct PersonalMemoryAuthorizationLedgerEntry: Sendable {
  let call: ToolCall
  let expiresAt: UInt64
}
