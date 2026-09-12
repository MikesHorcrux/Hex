import Foundation
import HexPersonality
import Testing

@Suite("Personal memory scope")
struct PersonalMemoryScopeTests {
  @Test("Accepts stable lowercase identifiers and validates decoding")
  func validatesScopeIdentifiers() throws {
    let scope = try PersonalMemoryScope(rawValue: "mike.hex_1")
    #expect(scope.rawValue == "mike.hex_1")
    #expect(
      try JSONDecoder().decode(PersonalMemoryScope.self, from: JSONEncoder().encode(scope))
        == scope
    )

    for invalid in ["", "Mike", ".mike", "mike/hex", "mike hex", "mike\0hex"] {
      #expect(throws: PersonalMemoryScopeError.invalidValue) {
        _ = try PersonalMemoryScope(rawValue: invalid)
      }
    }
  }
}
