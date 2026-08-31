import HexRuntime
import Testing

struct HexRuntimeModuleTests {
  @Test
  func declaresItsModuleIdentity() {
    #expect(HexRuntimeModule.name == "HexRuntime")
  }
}
