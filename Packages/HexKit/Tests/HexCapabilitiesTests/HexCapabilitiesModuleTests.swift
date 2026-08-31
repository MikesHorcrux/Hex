import HexCapabilities
import Testing

struct HexCapabilitiesModuleTests {
  @Test
  func declaresItsModuleIdentity() {
    #expect(HexCapabilitiesModule.name == "HexCapabilities")
  }
}
