import HexIPC
import Testing

struct HexIPCModuleTests {
  @Test
  func declaresItsModuleIdentity() {
    #expect(HexIPCModule.name == "HexIPC")
  }
}
