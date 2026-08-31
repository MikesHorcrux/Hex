import Foundation

/// Bounded login-flow identity and completion state for one physical app-server transport.
///
/// A transport instance owns exactly one controller and vends that same controller to every
/// account client constructed over it. History is deliberately never evicted: a fresh transport
/// and controller are the only way to regain the fixed 64-flow production capacity.
public actor CodexAccountLoginFlowGenerationController {
  private let capacity: Int
  private var ledger = CodexAccountLoginFlowLedger()
  private var reservation: UUID?
  private var activeLoginID: CodexLoginID?
  private var cancellationInProgressID: CodexLoginID?
  private var unboundCompletion: CodexLoginCompletion?
  private var completions: [CodexLoginID: CodexLoginCompletion] = [:]
  private var retired = false

  /// Creates the fixed-capacity controller for one newly constructed transport instance.
  ///
  /// A controller must not be shared by distinct transport instances.
  public init() {
    capacity = 64
  }

  init(validatedCapacity capacity: Int) {
    self.capacity = capacity
  }

  func reserveLoginStart() throws -> UUID {
    try ensureUsable()
    guard reservation == nil, activeLoginID == nil else {
      throw CodexAccountClientError.loginAlreadyPending
    }
    guard ledger.count < capacity else {
      throw CodexAccountClientError.loginFlowHistoryExhausted
    }
    let createdReservation = UUID()
    reservation = createdReservation
    return createdReservation
  }

  func abandonLoginStart(_ abandonedReservation: UUID) {
    guard reservation == abandonedReservation else { return }
    reservation = nil
    unboundCompletion = nil
  }

  func issue(
    _ loginID: CodexLoginID,
    reservation issuedReservation: UUID
  ) throws -> CodexLoginCompletion? {
    try ensureUsable()
    guard reservation == issuedReservation else {
      throw CodexAccountClientError.transitionInProgress
    }
    reservation = nil
    guard ledger.count < capacity else {
      throw CodexAccountClientError.loginFlowHistoryExhausted
    }
    try ledger.issue(loginID)
    activeLoginID = loginID

    guard let unboundCompletion else {
      return nil
    }
    self.unboundCompletion = nil
    guard unboundCompletion.loginID == loginID else {
      ledger.retire(loginID)
      activeLoginID = nil
      throw CodexAccountClientError.loginIdentifierMismatch
    }
    try acceptIssuedCompletion(unboundCompletion, for: loginID)
    return unboundCompletion
  }

  func retire(_ loginID: CodexLoginID) {
    ledger.retire(loginID)
    if activeLoginID == loginID {
      activeLoginID = nil
    }
    if cancellationInProgressID == loginID {
      cancellationInProgressID = nil
    }
  }

  func beginCancellation(for loginID: CodexLoginID) throws {
    try ensureUsable()
    guard cancellationInProgressID == nil else {
      throw CodexAccountClientError.transitionInProgress
    }
    guard activeLoginID == loginID, ledger.entry(for: loginID) == .pending else {
      throw CodexAccountClientError.noPendingLogin
    }
    cancellationInProgressID = loginID
  }

  func finishCancellation(for loginID: CodexLoginID) throws {
    try ensureUsable()
    guard cancellationInProgressID == loginID else {
      throw CodexAccountClientError.transitionInProgress
    }
    switch ledger.entry(for: loginID) {
    case .pending:
      ledger.retire(loginID)
    case .completionAccepted:
      break
    case .retiredAwaitingCompletion, .none:
      throw CodexAccountClientError.transitionInProgress
    }
    cancellationInProgressID = nil
    activeLoginID = nil
  }

  func abandonCancellation(for loginID: CodexLoginID) {
    guard cancellationInProgressID == loginID else { return }
    cancellationInProgressID = nil
    if ledger.entry(for: loginID) == .completionAccepted {
      activeLoginID = nil
    }
  }

  func entry(for loginID: CodexLoginID) -> CodexAccountLoginFlowLedgerEntry? {
    ledger.entry(for: loginID)
  }

  func acceptCompletion(_ completion: CodexLoginCompletion) throws {
    try ensureUsable()
    guard let loginID = completion.loginID else {
      throw CodexAccountClientError.loginIdentifierMismatch
    }
    switch ledger.entry(for: loginID) {
    case .pending, .retiredAwaitingCompletion:
      try acceptIssuedCompletion(completion, for: loginID)
    case .completionAccepted:
      throw CodexAccountClientError.unexpectedLoginCompletion
    case .none:
      guard reservation != nil else {
        if ledger.isEmpty {
          throw CodexAccountClientError.unexpectedLoginCompletion
        }
        throw CodexAccountClientError.loginIdentifierMismatch
      }
      guard unboundCompletion == nil else {
        throw CodexAccountClientError.unexpectedLoginCompletion
      }
      unboundCompletion = completion
    }
  }

  func completion(for loginID: CodexLoginID) -> CodexLoginCompletion? {
    if unboundCompletion?.loginID == loginID {
      return unboundCompletion
    }
    return completions[loginID]
  }

  /// Rejects I/O after this physical transport generation has been retired.
  public func ensureUsable() throws {
    guard !retired else {
      throw CodexAccountClientError.loginFlowGenerationRetired
    }
  }

  /// Atomically makes this generation terminal. Transport implementations call this immediately
  /// before awaiting their physical close. This operation is idempotent.
  public func retireGeneration() {
    retired = true
    reservation = nil
    activeLoginID = nil
    cancellationInProgressID = nil
    unboundCompletion = nil
  }

  private func acceptIssuedCompletion(
    _ completion: CodexLoginCompletion,
    for loginID: CodexLoginID
  ) throws {
    try ledger.acceptCompletion(for: loginID)
    completions[loginID] = completion
    if activeLoginID == loginID, cancellationInProgressID != loginID {
      activeLoginID = nil
    }
  }
}
