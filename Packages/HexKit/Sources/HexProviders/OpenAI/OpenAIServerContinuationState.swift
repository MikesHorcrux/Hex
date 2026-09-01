import HexCore

struct OpenAIServerContinuationState: Sendable {
  let responseID: String
  let modelID: ModelID
  let knownMessageIDs: [MessageID]
  let knownMessageFingerprints: [OpenAIMessageFingerprint]
  let outputItems: [JSONValue]
  let encodedByteCount: Int
}
