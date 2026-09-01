import HexCore

struct OpenAILocalContinuationState: Sendable {
  let responseID: String
  let modelID: ModelID
  let baseMessageCount: Int
  let knownMessageIDs: [MessageID]
  let knownMessageFingerprints: [OpenAIMessageFingerprint]
  let replaySegments: [OpenAILocalReplaySegment]
  let encodedByteCount: Int
}
