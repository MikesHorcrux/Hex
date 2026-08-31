import HexCore
import Testing

struct HexCoreModuleTests {
  @Test
  func declaresNoModuleDependencies() {
    #expect(HexCoreModule.dependencies.isEmpty)
  }
}
