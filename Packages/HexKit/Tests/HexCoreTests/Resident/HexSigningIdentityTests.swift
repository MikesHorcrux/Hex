import HexCore
import Testing

@Suite("Resident signing identity")
struct HexSigningIdentityTests {
  @Test
  func derivesTeamScopedBoundaries() throws {
    let identity = try #require(HexSigningIdentity(teamIdentifier: "AB12345678"))
    #expect(identity.residentKeychainAccessGroup == "AB12345678.com.lunarmothstudios.Hex.resident")
    #expect(
      identity.applicationCodeSigningRequirement
        == #"anchor apple generic and identifier "com.lunarmothstudios.Hex" and certificate leaf[subject.OU] = "AB12345678""#
    )
  }

  @Test(arguments: ["", "TEAM", "ab12345678", "AB1234567\"", "AB123456789", "AB1234567é"])
  func rejectsInvalidOrInjectedTeam(_ team: String) {
    #expect(HexSigningIdentity(teamIdentifier: team) == nil)
  }
}
