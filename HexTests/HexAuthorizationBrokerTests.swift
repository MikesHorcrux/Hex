import HexCapabilities
import HexCore
import Testing

@testable import Hex

@Suite("Authorization broker")
struct HexAuthorizationBrokerTests {
  @Test
  func sessionChoiceResolvesTheRuntimePrompt() async throws {
    let broker = HexAuthorizationBroker()
    let request = AuthorizationRequest(
      runID: AgentRunID(),
      capability: CapabilityID(rawValue: "filesystem.read"),
      operation: "list",
      explanation: "Read the configured workspace."
    )
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
}
