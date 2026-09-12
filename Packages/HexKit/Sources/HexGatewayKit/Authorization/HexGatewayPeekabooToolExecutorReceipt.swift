import Foundation
import HexCore

struct HexGatewayPeekabooToolExecutorReceipt {
  let id: String
  let runID: AgentRunID
  let sessionID: UUID
  let capturedAt: ContinuousClock.Instant
  let target: HexGatewayPeekabooObservation
}
