import HexPersistence
import Testing

struct HexPersistenceModuleTests {
  @Test
  func declaresItsModuleIdentity() {
    #expect(HexPersistenceModule.name == "HexPersistence")
  }
}
