import HexCore
import HexIPC
import Testing

@testable import Hex

@Suite("Tool guidance uses resident transport identity, not a server's chosen name")
struct HexToolConnectionPresentationTests {
  @Test(arguments: ["playwright", "peekaboo", "xcode"])
  func customServerKeepsItsOwnNameAndGenericRepair(serverID: String) {
    for transport: HexResidentMCPTransport? in [.streamableHTTP, nil] {
      let row = HexToolConnectionPresentation(
        status: .init(
          serverID: serverID, state: .unavailable, failure: .componentMissing,
          transport: transport))
      #expect(row.name == serverID)
      #expect(row.detail?.contains("Built-in tools") == false)
      #expect(row.detail?.contains("Open Xcode") == false)
    }
  }

  @Test
  func managedServerUsesVerifiedCapabilityName() {
    let row = HexToolConnectionPresentation(
      status: .init(
        serverID: "xcode", state: .unavailable, failure: .connectionFailed,
        transport: .xcode))
    #expect(row.name == "Xcode control")
    #expect(row.detail?.contains("Open Xcode") == true)
  }
}
