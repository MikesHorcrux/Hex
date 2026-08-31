import HexPersonality
import Testing

@Suite("Personal memory queries")
struct PersonalMemoryQueryTests {
  @Test
  func rejectsUnboundedOrMalformedQueries() {
    #expect(throws: PersonalMemoryStoreError.invalidQuery) {
      _ = try PersonalMemoryQuery(limit: 0)
    }
    #expect(throws: PersonalMemoryStoreError.invalidQuery) {
      _ = try PersonalMemoryQuery(text: " ", limit: 1)
    }
    #expect(throws: PersonalMemoryStoreError.invalidQuery) {
      _ = try PersonalMemoryQuery(
        text: Array(repeating: "term", count: 33).joined(separator: " "),
        limit: 1
      )
    }
  }
}
