import HexIPC
import Testing

@testable import Hex

@Suite("Gateway authorization decision adapter")
struct HexGatewayAuthorizationDecisionAdapterTests {
  @Test
  func mapsEveryAppChoiceToTheWireChoice() {
    #expect(
      HexGatewayAuthorizationDecisionAdapter.gatewayChoice(for: .allowOnce)
        == .allowOnce
    )
    #expect(
      HexGatewayAuthorizationDecisionAdapter.gatewayChoice(for: .allowForSession)
        == .allowForSession
    )
    #expect(
      HexGatewayAuthorizationDecisionAdapter.gatewayChoice(for: .deny)
        == .deny
    )
  }
}
