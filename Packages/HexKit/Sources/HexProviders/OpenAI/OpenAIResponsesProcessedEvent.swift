import HexCore

struct OpenAIResponsesProcessedEvent: Sendable {
  let events: [InferenceStreamEvent]
  let terminalResult: OpenAIResponsesStreamResult?
}
