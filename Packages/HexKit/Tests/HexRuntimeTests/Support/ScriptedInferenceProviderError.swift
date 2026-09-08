import HexCore

enum ScriptedInferenceProviderError: InferenceProviderFailure {
  case provider

  var userFacingMessage: String {
    "The test provider reported a safe failure."
  }

  var isRetryable: Bool {
    true
  }
}
