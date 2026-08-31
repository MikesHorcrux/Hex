import HexCore

struct OpenAIResponsesStreamResult: Sendable {
  let responseID: String
  let stopReason: InferenceStopReason
  let outputItems: [JSONValue]
  let encodedOutputBytes: Int
}
