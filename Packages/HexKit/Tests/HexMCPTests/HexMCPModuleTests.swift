import Testing

@testable import HexMCP

@Suite("HexMCP module")
struct HexMCPModuleTests {
  @Test("Declares its module identity")
  func declaresModuleIdentity() {
    #expect(HexMCPModule.name == "HexMCP")
  }
}
