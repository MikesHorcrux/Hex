/// User-triggered account actions for the Codex compatibility backend.
///
/// This boundary deliberately exposes no access token, refresh token, cookie, API key, or raw
/// login completion. The concrete manager keeps those concerns inside Codex and returns only the
/// challenge needed for the user and the redacted outcome needed by the settings UI.
public protocol CodexCompatibilityAccountManaging: Sendable {
  func startLogin(_ mode: CodexChatGPTLoginMode) async throws
    -> CodexCompatibilityLoginChallenge

  func completeLogin(_ loginID: CodexLoginID) async throws

  func cancelLogin(_ loginID: CodexLoginID) async throws -> CodexLoginCancellationStatus

  func logout() async throws

  /// Permanently closes the physical app-server/account generation.
  ///
  /// Implementations must return only after the underlying channel has stopped accepting I/O.
  func shutdown() async
}
