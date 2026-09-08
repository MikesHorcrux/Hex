import HexIPC
import HexMCP
import Testing

@testable import HexGatewayKit

@Suite("Gateway screen-control permission failure mapping")
struct HexGatewayScreenControlPermissionFailureMapperTests {
  @Test
  func missingInstallationProducesAnActionableRetryableFailure() {
    let failure = HexGatewayScreenControlPermissionFailureMapper.map(
      MCPManagedToolLayoutError.invalidInstallation(.peekaboo)
    )

    #expect(failure.code == .transportUnavailable)
    #expect(failure.isRetryable)
    #expect(failure.message.contains("missing or failed validation"))
  }

  @Test
  func timeoutProducesAUserFacingMessage() {
    let failure = HexGatewayScreenControlPermissionFailureMapper.map(
      MCPClientSessionError.requestTimedOut
    )

    #expect(failure.message == "Screen control did not respond in time. Try again.")
    #expect(failure.isRetryable)
  }

  @Test
  func unknownErrorsDoNotCrossTheBoundaryWithTheirDescription() {
    let failure = HexGatewayScreenControlPermissionFailureMapper.map(
      SecretBearingFailure(description: "secret local path")
    )

    #expect(!failure.message.contains("secret"))
    #expect(!failure.message.contains("path"))
  }

  private struct SecretBearingFailure: Error {
    let description: String
  }
}
