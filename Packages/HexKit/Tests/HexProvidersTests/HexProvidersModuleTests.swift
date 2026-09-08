import HexProviders
import Testing

struct HexProvidersModuleTests {
  @Test
  func declaresItsModuleIdentity() {
    #expect(HexProvidersModule.name == "HexProviders")
  }
}
