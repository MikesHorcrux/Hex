import Synchronization

/// Excludes authorization invalidation from the final broker commit for one XPC connection.
///
/// The gate is deliberately synchronous: the caller holds the lock while it validates and
/// consumes the pending request, so connection invalidation cannot close the session between those
/// operations. A closed gate rejects any commit that has not started yet.
public final class HexGatewayAuthorizationCommitGate: Sendable {
  public enum GateError: Error, Equatable, LocalizedError, Sendable {
    case closed

    public var errorDescription: String? {
      switch self {
      case .closed:
        "The authorization connection is no longer valid."
      }
    }
  }

  private struct State: Sendable {
    var isValid = true
  }

  private let storage = Mutex(State())

  public init() {}

  public var isValid: Bool {
    storage.withLock { state in
      state.isValid
    }
  }

  public func invalidate() {
    storage.withLock { state in
      state.isValid = false
    }
  }

  public func withValidCommit<Result>(
    _ operation: () throws -> Result
  ) throws -> Result {
    try storage.withLock { state in
      guard state.isValid else {
        throw GateError.closed
      }
      return try operation()
    }
  }
}
