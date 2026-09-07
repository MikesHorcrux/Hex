import HexCore
import HexIPC
import Testing

@testable import Hex

@Suite("Tool guidance uses resident transport identity, not a server's chosen name")
struct HexToolConnectionPresentationTests {
  @Test(arguments: ["playwright", "peekaboo", "xcode"])
  func customServerKeepsItsOwnNameAndGenericRepair(serverID: String) {
    for transport: HexResidentMCPTransport? in [.streamableHTTP, .stdio, nil] {
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
  func revokedAuthorizationProvidesTheCredentialRepairPath() {
    let row = HexToolConnectionPresentation(
      status: .init(
        serverID: "local", state: .unavailable, failure: .authenticationRejected,
        transport: .streamableHTTP))
    #expect(row.detail?.contains("bearer token") == true)
    #expect(row.detail?.contains("save, then retry") == true)
    #expect(row.actionTitle == "Retry connection")
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
