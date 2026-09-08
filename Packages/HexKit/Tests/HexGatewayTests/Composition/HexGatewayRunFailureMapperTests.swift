import HexCore
import HexIPC
import HexRuntime
import Testing

@testable import HexGatewayKit

@Suite("Gateway run failure mapping")
struct HexGatewayRunFailureMapperTests {
  @Test
  func providerFailureKeepsItsRedactedActionableMessage() {
    let failure = HexGatewayRunFailureMapper.map(
      .providerFailure("The inference provider failed to open a stream.", isRetryable: true)
    )

    #expect(failure.code == .runDriverFailed)
    #expect(failure.message == "The inference provider failed to open a stream.")
    #expect(failure.isRetryable)
  }

  @Test
  func deterministicProviderFailureIsNotMarkedRetryable() {
    let failure = HexGatewayRunFailureMapper.map(
      .providerFailure("The inference request is invalid.", isRetryable: false)
    )

    #expect(failure.code == .runDriverFailed)
    #expect(!failure.isRetryable)
  }

  @Test
  func invalidRequestIsNotMarkedRetryable() {
    let failure = HexGatewayRunFailureMapper.map(
      .invalidRequest("At least one initial message is required.")
    )

    #expect(failure.code == .runDriverFailed)
    #expect(!failure.isRetryable)
  }
}
