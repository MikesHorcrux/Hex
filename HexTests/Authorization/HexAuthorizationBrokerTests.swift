import HexCapabilities
import HexCore
import Testing

@testable import Hex

@Suite("Authorization broker")
struct HexAuthorizationBrokerTests {
  @Test
  func sessionChoiceResolvesTheRuntimePrompt() async throws {
    let broker = HexAuthorizationBroker()
    let request = Self.request()
    let decisionTask = Task {
      try await broker.requestDecision(for: request)
    }

    var submitted = false
    for _ in 0..<20 where !submitted {
      do {
        try await broker.submit(request, choice: .allowForSession)
        submitted = true
      } catch HexAuthorizationBroker.BrokerError.requestNotPending {
        await Task.yield()
      }
    }

    #expect(submitted)
    let response = try await decisionTask.value
    #expect(response == .allow(scope: .session))
  }

  @Test
  func cancellationBeforeWaiterRegistrationDoesNotLeaveAStaleRequest() async throws {
    let broker = HexAuthorizationBroker()
    let request = Self.request()
    let decisionTask = Task {
      try await broker.requestDecision(for: request)
    }
    decisionTask.cancel()

    do {
      _ = try await decisionTask.value
      Issue.record("Expected a cancelled authorization request.")
    } catch is CancellationError {
      // Expected.
    } catch {
      Issue.record("Unexpected cancellation error: \(error)")
    }

    let retryTask = Task {
      try await broker.requestDecision(for: request)
    }
    var submitted = false
    for _ in 0..<20 where !submitted {
      do {
        try await broker.submit(request, choice: .allowOnce)
        submitted = true
      } catch HexAuthorizationBroker.BrokerError.requestNotPending {
        await Task.yield()
      }
    }

    #expect(submitted)
    _ = try await retryTask.value
  }

  @Test
  func duplicatePendingRequestIsRejectedWithoutReplacingTheOriginal() async throws {
    let broker = HexAuthorizationBroker()
    let request = Self.request()
    let originalTask = Task {
      try await broker.requestDecision(for: request)
    }

    for _ in 0..<20 {
      await Task.yield()
    }

    let duplicateTask = Task {
      do {
        _ = try await broker.requestDecision(for: request)
        return false
      } catch HexAuthorizationBroker.BrokerError.requestAlreadyPending {
        return true
      } catch {
        return false
      }
    }

    #expect(await duplicateTask.value)
    var submitted = false
    for _ in 0..<20 where !submitted {
      do {
        try await broker.submit(request, choice: .allowOnce)
        submitted = true
      } catch HexAuthorizationBroker.BrokerError.requestNotPending {
        await Task.yield()
      }
    }

    #expect(submitted)
    #expect(try await originalTask.value == .allow(scope: .once))
  }

  private static func request() -> AuthorizationRequest {
    AuthorizationRequest(
      runID: AgentRunID(),
      capability: CapabilityID(rawValue: "filesystem.read"),
      operation: "list",
      explanation: "Read the configured workspace."
    )
  }
}
