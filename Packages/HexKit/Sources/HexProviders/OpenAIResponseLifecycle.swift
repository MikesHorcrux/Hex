enum OpenAIResponseLifecycle: Sendable {
  case awaitingStart
  case streaming
  case terminal
}
