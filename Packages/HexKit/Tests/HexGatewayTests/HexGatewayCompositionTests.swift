import HexGateway
import Testing

struct HexGatewayCompositionTests {
  @Test
  func includesEveryLibraryModule() {
    #expect(HexGatewayComposition.moduleNames.count == 8)
    #expect(HexGatewayComposition.moduleNames.contains("HexMCP"))
  }
}
