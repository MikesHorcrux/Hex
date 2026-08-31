import Foundation
import HexCore
import HexIPC
import Testing

@Suite("Gateway start response validation")
struct GatewayStartResponseValidationTests {
  @Test(arguments: [
    GatewayStartRunDisposition.started(invocationID: zeroInvocationID),
    GatewayStartRunDisposition.alreadyRunning(invocationID: zeroInvocationID),
    GatewayStartRunDisposition.alreadyTerminal(invocationID: zeroInvocationID),
    GatewayStartRunDisposition.busy(activeRunID: zeroRunID),
  ])
  func malformedDispositionIdentityIsRejected(
    disposition: GatewayStartRunDisposition
  ) async throws {
    let client = HexGatewayClient(
      transport: MalformedStartGatewayTransport(disposition: disposition)
    )
    _ = try await client.connect()

    do {
      _ = try await client.startRun(
        GatewayTestValues.request(runID: GatewayTestValues.runID(202))
      )
      Issue.record("Expected a zero response identity to be rejected.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .malformedPayload)
    }
  }

  @Test
  func busyResponseCannotNameTheRequestedRunAsItsConflict() async throws {
    let runID = GatewayTestValues.runID(203)
    let client = HexGatewayClient(
      transport: MalformedStartGatewayTransport(
        disposition: .busy(activeRunID: runID)
      )
    )
    _ = try await client.connect()

    do {
      _ = try await client.startRun(GatewayTestValues.request(runID: runID))
      Issue.record("Expected the contradictory busy response to be rejected.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .malformedPayload)
    }
  }

  private static let zeroUUID = UUID(
    uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
  )
  private static let zeroInvocationID = GatewayRunInvocationID(rawValue: zeroUUID)
  private static let zeroRunID = AgentRunID(rawValue: zeroUUID)
}
