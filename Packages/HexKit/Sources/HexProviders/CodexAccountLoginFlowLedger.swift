struct CodexAccountLoginFlowLedger: Sendable {
  private let capacity: Int
  private var entries: [CodexLoginID: CodexAccountLoginFlowLedgerEntry] = [:]

  init() {
    capacity = 64
  }

  init(validatedCapacity capacity: Int) {
    self.capacity = capacity
  }

  var hasCapacity: Bool {
    entries.count < capacity
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
    guard hasCapacity else {
      throw CodexAccountClientError.loginFlowHistoryExhausted
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
