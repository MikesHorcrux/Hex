import HexCore
import HexIPC

extension HexGatewayRunDriverAdapter: HexGatewayBoundaryStopping {
  public func stopAtBoundary(_ runID: AgentRunID) async {
    await runtime.stopAtBoundary(runID)
  }
}
