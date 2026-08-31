import HexPersonality
import Testing

@Suite("Personal memory queries")
struct PersonalMemoryQueryTests {
  @Test
  func rejectsUnboundedOrMalformedQueries() throws {
    let scope = try PersonalMemoryScope(rawValue: "mike.hex")
    #expect(throws: PersonalMemoryStoreError.invalidQuery) {
      _ = try PersonalMemoryQuery(scope: scope, limit: 0)
    }
    #expect(throws: PersonalMemoryStoreError.invalidQuery) {
      _ = try PersonalMemoryQuery(scope: scope, text: " ", limit: 1)
    }
    #expect(throws: PersonalMemoryStoreError.invalidQuery) {
      _ = try PersonalMemoryQuery(
        scope: scope,
        text: Array(repeating: "term", count: 33).joined(separator: " "),
        limit: 1
      )
    }
  }
}
