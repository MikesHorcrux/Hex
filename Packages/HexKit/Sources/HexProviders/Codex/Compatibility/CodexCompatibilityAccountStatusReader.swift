/// Maps the Codex app-server account projection into an honest compatibility-mode status.
public struct CodexCompatibilityAccountStatusReader: CodexCompatibilityAccountStatusProviding,
  Sendable
{
  private let accountReader: any CodexAccountReading

  public init(accountReader: any CodexAccountReading) {
    self.accountReader = accountReader
  }

  public func status() async -> CodexCompatibilityAccountStatus {
    do {
      return CodexCompatibilityAccountStatus(
        snapshot: try await accountReader.readAccount(refreshToken: false)
      )
    } catch is CancellationError {
      return .unavailable
    } catch {
      return .unavailable
    }
  }
}
