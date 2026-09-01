import Foundation
import HexCore

extension AgentRuntime {
  /// Performs a bounded advisory read before `.runStarted`. The journal's atomic duplicate-start
  /// rejection remains authoritative across concurrent runtimes and process restarts.
  func requireUnusedRunID(_ runID: AgentRunID) async throws {
    try Task.checkCancellation()
    let records: [AgentEventRecord]
    do {
      records = try await journal.records(for: runID, after: nil, limit: 1)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if Task.isCancelled {
        throw CancellationError()
      }
      throw AgentRuntimeError.journalFailure("The event journal failed to preflight the run ID.")
    }
    try Task.checkCancellation()
    guard records.isEmpty else {
      throw AgentRuntimeError.duplicateRun(runID)
    }
  }

  func append(_ event: AgentEvent, to runID: AgentRunID) async throws {
    try Task.checkCancellation()
    try validateJournalEventSize(event)
    try Task.checkCancellation()
    do {
      _ = try await journal.append(event, to: runID)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if Task.isCancelled {
        throw CancellationError()
      }
      throw AgentRuntimeError.journalFailure("The event journal failed to append a record.")
    }
  }

  /// Persists a known external tool outcome in a fresh task so cancellation of the calling run cannot
  /// erase the durable completion record after the executor has returned.
  func appendKnownOutcome(_ event: AgentEvent, to runID: AgentRunID) async throws {
    try validateJournalEventSize(event)
    let journal = self.journal
    do {
      _ = try await Task.detached {
        try await journal.append(event, to: runID)
      }.value
    } catch {
      throw AgentRuntimeError.journalFailure(
        "The event journal failed to persist a known tool outcome."
      )
    }
  }

  /// Persists the terminal run fact outside caller cancellation. Failure takes precedence over the
  /// triggering cancellation or runtime error because a nonterminal durable journal must fail closed.
  func appendTerminal(_ event: AgentEvent, to runID: AgentRunID) async throws {
    do {
      try validateJournalEventSize(event)
    } catch {
      throw AgentRuntimeError.journalFailure(
        "The terminal run state exceeds the configured journal event envelope."
      )
    }
    let journal = self.journal
    do {
      _ = try await Task.detached {
        try await journal.append(event, to: runID)
      }.value
    } catch {
      throw AgentRuntimeError.journalFailure(
        "The event journal failed to persist the terminal run state."
      )
    }
  }

  private func validateJournalEventSize(_ event: AgentEvent) throws {
    let byteCount: Int
    do {
      byteCount = try JSONEncoder().encode(event).count
    } catch {
      throw AgentRuntimeError.invalidState("A journal event could not be serialized.")
    }
    guard byteCount <= configuration.budget.maxJournalEventBytes else {
      throw AgentRuntimeError.budgetExceeded("Serialized journal event byte budget exceeded.")
    }
  }
}
