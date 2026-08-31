enum CodexAccountClientState: Equatable, Sendable {
  case idle
  case starting(CodexChatGPTLoginMode, CodexLoginCompletion?)
  case awaiting(CodexLoginID)
  case cancelling(CodexLoginID)
  case loggingOut
}
