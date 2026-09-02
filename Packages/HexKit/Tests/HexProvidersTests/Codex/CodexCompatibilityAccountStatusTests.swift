import Testing

@testable import HexProviders

@Suite("Codex compatibility account status")
struct CodexCompatibilityAccountStatusTests {
  @Test
  func mapsRedactedAccountSnapshotsToHonestStatuses() throws {
    let plan = try CodexAccountPlan(rawValue: "plus")
    let account = CodexAccount.chatGPT(email: "person@example.com", plan: plan)
    let signedIn = CodexCompatibilityAccountStatus(
      snapshot: CodexAccountSnapshot(account: account, requiresOpenAIAuthentication: false)
    )
    let requiresAuthentication = CodexCompatibilityAccountStatus(
      snapshot: CodexAccountSnapshot(account: account, requiresOpenAIAuthentication: true)
    )
    let signedOut = CodexCompatibilityAccountStatus(
      snapshot: CodexAccountSnapshot(account: nil, requiresOpenAIAuthentication: false)
    )

    #expect(signedIn == .signedIn(account: account))
    #expect(signedIn.title == "Codex account available")
    #expect(signedIn.detail.contains("does not receive"))
    #expect(requiresAuthentication == .requiresOpenAIAuthentication)
    #expect(signedOut == .signedOut)
  }

  @Test
  func convertsAccountReaderFailuresToUnavailable() async {
    let reader = CodexCompatibilityAccountStatusReader(
      accountReader: ScriptedAccountReader(outcome: .failure)
    )

    #expect(await reader.status() == .unavailable)
  }

  @Test
  func preservesSignedInAccountProjectionThroughReader() async throws {
    let plan = try CodexAccountPlan(rawValue: "team")
    let account = CodexAccount.chatGPT(email: nil, plan: plan)
    let reader = CodexCompatibilityAccountStatusReader(
      accountReader: ScriptedAccountReader(
        outcome: .snapshot(
          CodexAccountSnapshot(account: account, requiresOpenAIAuthentication: false)
        )
      )
    )

    #expect(await reader.status() == .signedIn(account: account))
  }

  private enum ScriptedOutcome: Sendable {
    case snapshot(CodexAccountSnapshot)
    case failure
  }

  private actor ScriptedAccountReader: CodexAccountReading {
    let outcome: ScriptedOutcome

    init(outcome: ScriptedOutcome) {
      self.outcome = outcome
    }

    func readAccount(refreshToken: Bool) async throws -> CodexAccountSnapshot {
      switch outcome {
      case .snapshot(let snapshot):
        snapshot
      case .failure:
        throw ScriptedError.unavailable
      }
    }
  }

  private enum ScriptedError: Error, Sendable {
    case unavailable
  }
}
