import Foundation

/// Bounded login-flow identity and completion state for one physical app-server transport.
///
/// A transport instance owns exactly one controller and vends that same controller to every
/// account client constructed over it. History is deliberately never evicted: a fresh transport
/// and controller are the only way to regain the fixed 64-flow production capacity.
public actor CodexAccountLoginFlowGenerationController {
  private enum Transition: Equatable {
    case idle
    case starting(reservation: UUID, owner: UUID)
    case awaiting(CodexLoginID)
    case cancelling(loginID: CodexLoginID, owner: UUID)
    case loggingOut(reservation: UUID, owner: UUID)
  }

  private let capacity: Int
  private var ledger = CodexAccountLoginFlowLedger()
  private var transition = Transition.idle
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

  func reserveLoginStart(owner: UUID) throws -> UUID {
    try ensureUsable()
    switch transition {
    case .idle:
      break
    case .awaiting:
      throw CodexAccountClientError.loginAlreadyPending
    case .starting(_, let existingOwner), .cancelling(_, let existingOwner):
      if existingOwner == owner {
        throw CodexAccountClientError.transitionInProgress
      }
      throw CodexAccountClientError.loginAlreadyPending
    case .loggingOut:
      throw CodexAccountClientError.transitionInProgress
    }
    guard ledger.count < capacity else {
      throw CodexAccountClientError.loginFlowHistoryExhausted
    }
    let createdReservation = UUID()
    transition = .starting(reservation: createdReservation, owner: owner)
    return createdReservation
  }

  /// Atomically tombstones an admitted start, if one exists, and retires this generation.
  ///
  /// A failed login-start request is ambiguous. Keeping the tombstone and terminal retirement in
  /// one actor turn prevents another facade from reserving the generation between start cleanup
  /// and physical transport teardown.
  func retireAfterAmbiguousStart(
    reservation: UUID,
    admittedLoginID: CodexLoginID?
  ) {
    if let admittedLoginID {
      ledger.retire(admittedLoginID)
      switch transition {
      case .awaiting(admittedLoginID), .cancelling(admittedLoginID, _):
        transition = .idle
      case .idle, .starting, .awaiting, .cancelling, .loggingOut:
        break
      }
    }
    if case .starting(reservation, _) = transition {
      transition = .idle
      unboundCompletion = nil
    }
    retired = true
  }

  func issue(
    _ loginID: CodexLoginID,
    reservation issuedReservation: UUID
  ) throws -> CodexLoginCompletion? {
    try ensureUsable()
    guard case .starting(issuedReservation, _) = transition else {
      throw CodexAccountClientError.transitionInProgress
    }
    guard ledger.count < capacity else {
      throw CodexAccountClientError.loginFlowHistoryExhausted
    }
    try ledger.issue(loginID)
    transition = .awaiting(loginID)

    guard let unboundCompletion else {
      return nil
    }
    self.unboundCompletion = nil
    guard unboundCompletion.loginID == loginID else {
      ledger.retire(loginID)
      transition = .idle
      throw CodexAccountClientError.loginIdentifierMismatch
    }
    try acceptIssuedCompletion(unboundCompletion, for: loginID)
    return unboundCompletion
  }

  func beginCancellation(for loginID: CodexLoginID, owner: UUID) throws {
    try ensureUsable()
    switch transition {
    case .awaiting(let activeLoginID):
      guard activeLoginID == loginID else {
        throw CodexAccountClientError.loginIdentifierMismatch
      }
      guard ledger.entry(for: loginID) == .pending else {
        throw CodexAccountClientError.noPendingLogin
      }
      transition = .cancelling(loginID: loginID, owner: owner)
    case .idle:
      throw CodexAccountClientError.noPendingLogin
    case .starting, .cancelling, .loggingOut:
      throw CodexAccountClientError.transitionInProgress
    }
  }

  func finishCancellation(for loginID: CodexLoginID, owner: UUID) throws {
    try ensureUsable()
    guard case .cancelling(loginID, owner: owner) = transition else {
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
    transition = .idle
  }

  func abandonCancellation(for loginID: CodexLoginID, owner: UUID) {
    guard case .cancelling(loginID, owner: owner) = transition else { return }
    if ledger.entry(for: loginID) == .completionAccepted {
      transition = .idle
    } else {
      transition = .awaiting(loginID)
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
      guard case .starting = transition else {
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

  func reserveLogout(owner: UUID) throws -> UUID {
    try ensureUsable()
    switch transition {
    case .idle:
      let reservation = UUID()
      transition = .loggingOut(reservation: reservation, owner: owner)
      return reservation
    case .awaiting:
      throw CodexAccountClientError.loginAlreadyPending
    case .starting, .cancelling, .loggingOut:
      throw CodexAccountClientError.transitionInProgress
    }
  }

  func finishLogout(for reservation: UUID, owner: UUID) throws {
    try ensureUsable()
    guard case .loggingOut(reservation, owner: owner) = transition else {
      throw CodexAccountClientError.transitionInProgress
    }
    transition = .idle
  }

  func abandonLogout(_ reservation: UUID, owner: UUID) {
    guard case .loggingOut(reservation, owner: owner) = transition else { return }
    transition = .idle
  }

  /// Atomically makes this generation terminal. Transport implementations call this immediately
  /// before awaiting their physical close. This operation is idempotent.
  public func retireGeneration() {
    retired = true
    transition = .idle
    unboundCompletion = nil
  }

  private func acceptIssuedCompletion(
    _ completion: CodexLoginCompletion,
    for loginID: CodexLoginID
  ) throws {
    try ledger.acceptCompletion(for: loginID)
    completions[loginID] = completion
    if transition == .awaiting(loginID) {
      transition = .idle
    }
  }
}
