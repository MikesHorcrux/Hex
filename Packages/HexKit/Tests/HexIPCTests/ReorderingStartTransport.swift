import HexCore
import HexIPC

actor ReorderingStartTransport: HexGatewayTransport {
  private let delayedDisposition: GatewayStartRunDisposition
  private let delayedFailure: GatewayFailure?
  private let delayedResponseRunID: AgentRunID?
  private let newInvocationID = GatewayTestValues.invocationID(92)
  private var startCount = 0
  private var firstContinuation: CheckedContinuation<GatewayStartRunResponse, any Error>?
  private var firstRunID: AgentRunID?

  init(
    delayedDisposition: GatewayStartRunDisposition = .started(
      invocationID: GatewayTestValues.invocationID(91)
    ),
    delayedFailure: GatewayFailure? = nil,
    delayedResponseRunID: AgentRunID? = nil
  ) {
    self.delayedDisposition = delayedDisposition
    self.delayedFailure = delayedFailure
    self.delayedResponseRunID = delayedResponseRunID
  }

  func handshake(_ request: GatewayHandshakeRequest) -> GatewayHandshakeResponse {
    GatewayHandshakeResponse(
      sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(90)),
      gatewayInstanceID: GatewayInstanceID(rawValue: GatewayTestValues.uuid(90)),
      selectedVersion: .current,
      activeRun: nil
    )
  }

  func startRun(_ request: GatewayStartRunRequest) async throws -> GatewayStartRunResponse {
    startCount += 1
    if startCount == 1 {
      firstRunID = request.runID
      return try await withCheckedThrowingContinuation { continuation in
        firstContinuation = continuation
      }
    }

    return GatewayStartRunResponse(
      runID: request.runID,
      disposition: .started(invocationID: newInvocationID)
    )
  }

  func cancelRun(_ request: GatewayCancelRunRequest) -> GatewayCancelRunResponse {
    GatewayCancelRunResponse(
      runID: request.runID,
      invocationID: request.invocationID,
      disposition: .requested
    )
  }

  func eventRecords(
    after cursor: GatewayEventCursor
  ) -> AsyncThrowingStream<AgentEventRecord, any Error> {
    AsyncThrowingStream { continuation in
      continuation.finish()
    }
  }

  func disconnect() {}

  func waitUntilFirstStartIsPending() async {
    while firstContinuation == nil {
      await Task.yield()
    }
  }

  func releaseFirstStart() {
    guard let firstContinuation, let firstRunID else {
      return
    }
    self.firstContinuation = nil
    if let delayedFailure {
      firstContinuation.resume(throwing: delayedFailure)
      return
    }
    firstContinuation.resume(
      returning: GatewayStartRunResponse(
        runID: delayedResponseRunID ?? firstRunID,
        disposition: delayedDisposition
      )
    )
  }
}
