/// Read-only account projection used by compatibility-mode status surfaces.
///
/// This boundary exposes the redacted `CodexAccountSnapshot` only. It never exposes a token,
/// cookie, auth file, or raw inference credential.
public protocol CodexAccountReading: Sendable {
  func readAccount(refreshToken: Bool) async throws -> CodexAccountSnapshot
}
