import HexPersonality
import Testing

struct HexPersonalityModuleTests {
  @Test
  func declaresItsModuleIdentity() {
    #expect(HexPersonalityModule.name == "HexPersonality")
  }
}
