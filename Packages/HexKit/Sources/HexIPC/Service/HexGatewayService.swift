import Foundation
import HexCore

/// The sole mutable owner of gateway sessions, run lifecycle, replay buffers, and live subscribers.
/// It runs in the caller's process and provides no XPC boundary, service installation, persistence
/// across app termination, sandbox escape, or additional filesystem/terminal authority.
/// Public typed inputs and emitted values are canonicalized with this service's configured wire
/// envelope before they can mutate service state; a transport may tighten but cannot widen it.
public actor HexGatewayService {
  let driver: any HexGatewayRunDriver
  let configuration: GatewayConfiguration
  let codec: GatewayWireCodec
  let gatewayInstanceID: GatewayInstanceID
  let historyReader: (any HexGatewayRunHistoryReading)?
  let conversationStore: (any ConversationStorage)?
  let artifactReader: (any ArtifactReading)?
  var sessions: [GatewaySessionID: GatewaySessionState] = [:]
  var runs: [AgentRunID: GatewayRunState] = [:]
  var completedRunOrder: [AgentRunID] = []
  var activeRunID: AgentRunID?
  // Replay entries may be evicted after a terminal event while their drivers are still unwinding.
  // This separate registry retains ownership until the actual task has returned.
  var liveDriverTasks: [GatewayRunInvocationID: Task<Void, Never>] = [:]
  var toolMaintenance: (id: UUID, cancel: @Sendable () -> Void)?
  var admissionsClosed = false
  var shutdownFinalized = false
  var drainWaiters: [UUID: GatewayDriverDrainWaiter] = [:]

  public init(
    driver: any HexGatewayRunDriver,
    configuration: GatewayConfiguration = .standard,
    gatewayInstanceID: GatewayInstanceID = GatewayInstanceID(),
    historyReader: (any HexGatewayRunHistoryReading)? = nil,
    artifactReader: (any ArtifactReading)? = nil,
    conversationStore: (any ConversationStorage)? = nil
  ) {
    self.driver = driver
    self.configuration = configuration
    codec = GatewayWireCodec(configuration: configuration)
    self.gatewayInstanceID = gatewayInstanceID
    self.historyReader = historyReader
    self.artifactReader = artifactReader
    self.conversationStore = conversationStore
  }

  func requireValidGatewayIdentity(
    _ rawValue: UUID,
    message: String
  ) throws {
    let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    guard rawValue != zeroUUID else {
      throw GatewayFailure(code: .malformedPayload, message: message)
    }
  }
}
