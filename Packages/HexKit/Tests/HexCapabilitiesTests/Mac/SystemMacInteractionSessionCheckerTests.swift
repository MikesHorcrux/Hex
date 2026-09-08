import HexCapabilities
import Testing

@Suite("Native interaction session classification")
struct SystemMacInteractionSessionCheckerTests {
  @Test
  func reportedLockAlwaysBlocksEvenWhenConsoleAndLoginAreAvailable() {
    #expect(
      SystemMacInteractionSessionChecker.classify(
        isOnConsole: true, loginComplete: true, screenIsLocked: true) == .locked)
    #expect(
      SystemMacInteractionSessionChecker.classify(
        isOnConsole: nil, loginComplete: nil, screenIsLocked: true) == .locked)
  }

  @Test
  func absentOrInactiveConsoleAndLoginFailClosed() {
    for console: Bool? in [nil, false] {
      #expect(
        SystemMacInteractionSessionChecker.classify(
          isOnConsole: console, loginComplete: true, screenIsLocked: nil) == .unavailable)
    }
    for login: Bool? in [nil, false] {
      #expect(
        SystemMacInteractionSessionChecker.classify(
          isOnConsole: true, loginComplete: login, screenIsLocked: false) == .unavailable)
    }
  }

  @Test
  func availableConsoleWithNoReportedLockDoesNotRequireAnAbsentRuntimeKey() {
    #expect(
      SystemMacInteractionSessionChecker.classify(
        isOnConsole: true, loginComplete: true, screenIsLocked: nil) == .available)
    #expect(
      SystemMacInteractionSessionChecker.classify(
        isOnConsole: true, loginComplete: true, screenIsLocked: false) == .available)
  }
}
