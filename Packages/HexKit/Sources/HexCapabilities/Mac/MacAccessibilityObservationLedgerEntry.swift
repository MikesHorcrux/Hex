import Dispatch
import Foundation
import HexCore

struct MacAccessibilityObservationLedgerEntry: Sendable {
  let runID: AgentRunID
  let snapshot: MacAccessibilitySnapshot
  let capturedAt: UInt64
  let expiresAt: UInt64
}
