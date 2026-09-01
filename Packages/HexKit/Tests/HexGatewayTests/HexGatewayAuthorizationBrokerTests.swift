import HexCapabilities
import HexCore
import HexGatewayKit
import HexIPC
import Testing

@Suite("Resident authorization broker")
struct HexGatewayAuthorizationBrokerTests {
  @Test
  func requiresExactPendingRequestAndConsumesAResponseOnce() async throws {
    let broker = HexGatewayAuthorizationBroker()
    let request = AuthorizationRequest(
      runID: AgentRunID(),
      toolCallID: ToolCallID(),
      capability: CapabilityID(rawValue: "process.execute"),
      operation: "run",
      resource: "/usr/bin/true",
      details: ["argv_count": .integer(1)],
      explanation: "Allow this exact process invocation."
    )
    let pending = Task {
      try await broker.requestDecision(for: request)
    }

    for _ in 0..<100 where !(await broker.isPending(request.id)) {
      await Task.yield()
    }
    #expect(await broker.isPending(request.id))

    let mismatched = AuthorizationRequest(
      id: request.id,
      runID: request.runID,
      toolCallID: request.toolCallID,
      capability: request.capability,
      operation: "different-operation",
      resource: request.resource,
      details: request.details,
      explanation: request.explanation
    )
    do {
      try await broker.submit(mismatched, choice: .allowOnce)
      Issue.record("Expected an exact authorization request mismatch.")
    } catch let error as HexGatewayAuthorizationBroker.BrokerError {
      #expect(error == .requestMismatch)
    }

    try await broker.submit(request, choice: .allowOnce)
    #expect(try await pending.value == .allow(scope: .once))
    #expect(await broker.isPending(request.id) == false)

    do {
      try await broker.submit(request, choice: .allowForSession)
      Issue.record("Expected a consumed authorization request to reject duplicates.")
    } catch let error as HexGatewayAuthorizationBroker.BrokerError {
      #expect(error == .requestNotPending)
    }
  }
}
