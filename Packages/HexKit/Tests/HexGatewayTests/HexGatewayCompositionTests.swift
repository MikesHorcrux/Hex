import HexGateway
import Testing

struct HexGatewayCompositionTests {
  @Test
  func includesEveryLibraryModule() {
    #expect(HexGatewayComposition.moduleNames.count == 7)
  }
}
