struct CodexAccountLoginFlowLedger: Sendable {
  private var entries: [CodexLoginID: CodexAccountLoginFlowLedgerEntry] = [:]

  var count: Int {
    entries.count
  }

  var isEmpty: Bool {
    entries.isEmpty
  }

  func entry(for loginID: CodexLoginID) -> CodexAccountLoginFlowLedgerEntry? {
    entries[loginID]
  }

  mutating func issue(_ loginID: CodexLoginID) throws {
    guard entries[loginID] == nil else {
      throw CodexAccountClientError.loginIdentifierReused
    }
    entries[loginID] = .pending
  }

  mutating func retire(_ loginID: CodexLoginID) {
    guard entries[loginID] == .pending else { return }
    entries[loginID] = .retiredAwaitingCompletion
  }

  mutating func acceptCompletion(for loginID: CodexLoginID) throws {
    switch entries[loginID] {
    case .pending, .retiredAwaitingCompletion:
      entries[loginID] = .completionAccepted
    case .completionAccepted:
      throw CodexAccountClientError.unexpectedLoginCompletion
    case .none:
      throw CodexAccountClientError.loginIdentifierMismatch
    }
  }
}
