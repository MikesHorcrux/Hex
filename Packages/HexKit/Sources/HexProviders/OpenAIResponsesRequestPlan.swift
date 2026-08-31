import Foundation
import HexCore

struct OpenAIResponsesRequestPlan: Sendable {
  let body: Data
  let priorServerState: OpenAIServerContinuationState?
  let priorLocalState: OpenAILocalContinuationState?
  let currentMessageIDs: [MessageID]
  let currentMessageFingerprints: [OpenAIMessageFingerprint]
}
