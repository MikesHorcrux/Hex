import HexCore
import HexIPC

actor HostileLifecycleGatewayTransport: HexGatewayTransport {
  private let initialResponse: GatewayHandshakeResponse
  private let holdsDisconnect: Bool
  private let holdsEventRecordsResponse: Bool
  private var handshakeCount = 0
  private var latestHandshakeIndex = 0
  private var handshakeContinuations:
    [Int: CheckedContinuation<GatewayHandshakeResponse, any Error>] = [:]
  private var handshakeLeases: [Int: GatewayTransportConnectionLease] = [:]
  private var startContinuation: CheckedContinuation<GatewayStartRunResponse, any Error>?
  private var cancelContinuation: CheckedContinuation<GatewayCancelRunResponse, any Error>?
  private var eventRecordsContinuation:
    CheckedContinuation<AsyncThrowingStream<AgentEventRecord, any Error>, any Error>?
  private var streamContinuation: AsyncThrowingStream<AgentEventRecord, any Error>.Continuation?
  private var disconnectContinuation: CheckedContinuation<Void, Never>?
  private var connectedLease: GatewayTransportConnectionLease?
  private(set) var disconnectCount = 0

  init(
    selectedVersion: GatewayProtocolVersion = .current,
    holdsDisconnect: Bool = false,
    holdsEventRecordsResponse: Bool = false
  ) {
    initialResponse = GatewayHandshakeResponse(
      sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(240)),
      gatewayInstanceID: GatewayInstanceID(rawValue: GatewayTestValues.uuid(240)),
      selectedVersion: selectedVersion,
      activeRun: nil
    )
    self.holdsDisconnect = holdsDisconnect
    self.holdsEventRecordsResponse = holdsEventRecordsResponse
  }

  init(
    initialResponse: GatewayHandshakeResponse,
    holdsDisconnect: Bool = false,
    holdsEventRecordsResponse: Bool = false
  ) {
    self.initialResponse = initialResponse
    self.holdsDisconnect = holdsDisconnect
    self.holdsEventRecordsResponse = holdsEventRecordsResponse
  }

  func handshake(
    _ request: GatewayHandshakeRequest,
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayHandshakeResponse {
    handshakeCount += 1
    let index = handshakeCount
    latestHandshakeIndex = index
    if index == 1 {
      connectedLease = lease
      return initialResponse
    }
    return try await withCheckedThrowingContinuation { continuation in
      handshakeContinuations[index] = continuation
      handshakeLeases[index] = lease
    }
  }

  func startRun(
    _ request: GatewayStartRunRequest,
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayStartRunResponse {
    try requireConnection(lease)
    return try await withCheckedThrowingContinuation { continuation in
      startContinuation = continuation
    }
  }

  func cancelRun(
    _ request: GatewayCancelRunRequest,
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayCancelRunResponse {
    try requireConnection(lease)
    return try await withCheckedThrowingContinuation { continuation in
      cancelContinuation = continuation
    }
  }

  func eventRecords(
    after cursor: GatewayEventCursor,
    lease: GatewayTransportConnectionLease
  ) async throws -> AsyncThrowingStream<AgentEventRecord, any Error> {
    try requireConnection(lease)
    if holdsEventRecordsResponse {
      return try await withCheckedThrowingContinuation { continuation in
        eventRecordsContinuation = continuation
      }
    }
    return installStream()
  }

  func disconnect(lease: GatewayTransportConnectionLease) async {
    disconnectCount += 1
    if holdsDisconnect {
      await withCheckedContinuation { continuation in
        disconnectContinuation = continuation
      }
    }
    guard connectedLease == lease else {
      return
    }
    connectedLease = nil
  }

  private func installStream() -> AsyncThrowingStream<AgentEventRecord, any Error> {
    let pair = AsyncThrowingStream<AgentEventRecord, any Error>.makeStream()
    streamContinuation = pair.continuation
    return pair.stream
  }

  func waitUntilHandshakeIsPending(_ index: Int) async {
    while handshakeContinuations[index] == nil {
      await Task.yield()
    }
  }

  func resolveHandshake(
    _ index: Int,
    instanceSeed: UInt8,
    selectedVersion: GatewayProtocolVersion = .current
  ) {
    let lease = handshakeLeases.removeValue(forKey: index)
    if latestHandshakeIndex == index {
      connectedLease = lease
    }
    handshakeContinuations.removeValue(forKey: index)?.resume(
      returning: GatewayHandshakeResponse(
        sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(instanceSeed)),
        gatewayInstanceID: GatewayInstanceID(rawValue: GatewayTestValues.uuid(instanceSeed)),
        selectedVersion: selectedVersion,
        activeRun: nil
      )
    )
  }

  func failHandshake(_ index: Int, message: String) {
    handshakeLeases.removeValue(forKey: index)
    handshakeContinuations.removeValue(forKey: index)?.resume(
      throwing: GatewayFailure(
        code: .transportUnavailable,
        message: message,
        isRetryable: true
      )
    )
  }

  func waitUntilStartIsPending() async {
    while startContinuation == nil {
      await Task.yield()
    }
  }

  func resolveStart(
    runID: AgentRunID,
    invocationID: GatewayRunInvocationID
  ) {
    startContinuation?.resume(
      returning: GatewayStartRunResponse(
        runID: runID,
        disposition: .started(invocationID: invocationID)
      )
    )
    startContinuation = nil
  }

  func failStart(message: String) {
    startContinuation?.resume(
      throwing: GatewayFailure(
        code: .transportUnavailable,
        message: message,
        isRetryable: true
      )
    )
    startContinuation = nil
  }

  func waitUntilCancelIsPending() async {
    while cancelContinuation == nil {
      await Task.yield()
    }
  }

  func resolveCancel(
    runID: AgentRunID,
    invocationID: GatewayRunInvocationID,
    disposition: GatewayCancelRunDisposition = .requested
  ) {
    cancelContinuation?.resume(
      returning: GatewayCancelRunResponse(
        runID: runID,
        invocationID: invocationID,
        disposition: disposition
      )
    )
    cancelContinuation = nil
  }

  func failCancel(message: String) {
    cancelContinuation?.resume(
      throwing: GatewayFailure(
        code: .transportUnavailable,
        message: message,
        isRetryable: true
      )
    )
    cancelContinuation = nil
  }

  func waitUntilEventRecordsIsPending() async {
    while eventRecordsContinuation == nil {
      await Task.yield()
    }
  }

  func resolveEventRecords() {
    eventRecordsContinuation?.resume(returning: installStream())
    eventRecordsContinuation = nil
  }

  func failEventRecords(message: String) {
    eventRecordsContinuation?.resume(
      throwing: GatewayFailure(
        code: .transportUnavailable,
        message: message,
        isRetryable: true
      )
    )
    eventRecordsContinuation = nil
  }

  func waitUntilStreamIsInstalled() async {
    while streamContinuation == nil {
      await Task.yield()
    }
  }

  func emit(_ record: AgentEventRecord) {
    streamContinuation?.yield(record)
  }

  func finishStream() {
    streamContinuation?.finish()
    streamContinuation = nil
  }

  func waitUntilDisconnectIsPending() async {
    while disconnectContinuation == nil {
      await Task.yield()
    }
  }

  func resolveDisconnect() {
    disconnectContinuation?.resume()
    disconnectContinuation = nil
  }

  private func requireConnection(_ lease: GatewayTransportConnectionLease) throws {
    guard connectedLease == lease else {
      throw GatewayFailure(
        code: .notConnected,
        message: "The hostile transport lease is not connected."
      )
    }
  }
}
