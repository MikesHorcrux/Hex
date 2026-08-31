enum CodexAccountClientState: Equatable, Sendable {
  case idle
  case starting(CodexChatGPTLoginMode)
  case awaiting(CodexLoginID)
  case cancelling(CodexLoginID, CodexLoginCompletion?)
  case loggingOut
}
