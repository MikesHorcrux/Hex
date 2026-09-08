import HexCore

public protocol HexGatewayBoundaryStopping: Sendable {
  func stopAtBoundary(_ runID: AgentRunID) async
}
