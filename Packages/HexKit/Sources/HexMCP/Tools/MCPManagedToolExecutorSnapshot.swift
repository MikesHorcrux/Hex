/// Cached managed-server health, without starting a connection or reading remote state.
public struct MCPManagedToolExecutorSnapshot: Equatable, Sendable {
  public let serverID: String
  public let state: MCPManagedToolExecutorState
  public let failure: MCPManagedToolFailure?
  public let availableToolCount: Int?

  public init(
    serverID: String,
    state: MCPManagedToolExecutorState,
    failure: MCPManagedToolFailure? = nil,
    availableToolCount: Int? = nil
  ) {
    self.serverID = serverID
    self.state = state
    self.failure = failure
    self.availableToolCount = availableToolCount
  }
}
