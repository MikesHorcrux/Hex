import HexMLXProvider
import Testing

struct HexMLXProviderModuleTests {
  @Test
  func declaresItsModuleIdentity() {
    #expect(HexMLXProviderModule.name == "HexMLXProvider")
  }
}
