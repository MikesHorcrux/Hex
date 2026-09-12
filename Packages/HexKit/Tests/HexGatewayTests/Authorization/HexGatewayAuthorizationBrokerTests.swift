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
    let gate = HexGatewayAuthorizationCommitGate()
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
      try await broker.submit(mismatched, choice: .allowOnce, gate: gate)
      Issue.record("Expected an exact authorization request mismatch.")
    } catch let error as HexGatewayAuthorizationBrokerError {
      #expect(error == .requestMismatch)
    }

    try await broker.submit(request, choice: .allowOnce, gate: gate)
    #expect(try await pending.value == .allow(scope: .once))
    #expect(await broker.isPending(request.id) == false)

    do {
      try await broker.submit(request, choice: .allowForSession, gate: gate)
      Issue.record("Expected a consumed authorization request to reject duplicates.")
    } catch let error as HexGatewayAuthorizationBrokerError {
      #expect(error == .requestNotPending)
    }
  }

  @Test
  func invalidatedCommitGateLeavesTheExactRequestPending() async throws {
    let broker = HexGatewayAuthorizationBroker()
    let request = AuthorizationRequest(
      runID: AgentRunID(),
      capability: CapabilityID(rawValue: "process.execute"),
      operation: "run",
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

    let gate = HexGatewayAuthorizationCommitGate()
    gate.invalidate()
    do {
      try await broker.submit(request, choice: .allowOnce, gate: gate)
      Issue.record("Expected an invalidated authorization commit gate to reject the response.")
    } catch let error as HexGatewayAuthorizationBrokerError {
      #expect(error == .requestNotPending)
    }
    #expect(await broker.isPending(request.id))

    pending.cancel()
    do {
      _ = try await pending.value
      Issue.record("Expected cancellation to release the pending authorization request.")
    } catch is CancellationError {
      // Expected.
    }
  }
}
