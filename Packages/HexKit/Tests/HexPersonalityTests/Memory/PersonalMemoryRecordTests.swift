import Foundation
import HexPersonality
import Testing

@Suite("Personal memory records")
struct PersonalMemoryRecordTests {
  @Test
  func recordsOnlyExplicitUserApprovedSources() throws {
    let timestamp = Date(timeIntervalSince1970: 42)
    let scope = try PersonalMemoryScope(rawValue: "mike.hex")
    let record = try PersonalMemoryRecord(
      scope: scope,
      id: PersonalMemoryID(rawValue: "memory-1"),
      kind: .preference,
      text: "Mike prefers Swift examples.",
      source: .explicitUserStatement,
      createdAt: timestamp,
      updatedAt: timestamp,
      isPinned: true
    )

    #expect(record.scope == scope)
    #expect(record.source == .explicitUserStatement)
    #expect(record.isPinned)
    #expect(
      try JSONDecoder().decode(PersonalMemoryRecord.self, from: JSONEncoder().encode(record))
        == record)
  }

  @Test
  func rejectsInvalidIdentityTextAndTimestamps() throws {
    let scope = try PersonalMemoryScope(rawValue: "mike.hex")
    #expect(throws: PersonalMemoryError.self) {
      _ = try PersonalMemoryRecord(
        scope: scope,
        id: PersonalMemoryID(rawValue: ""),
        kind: .fact,
        text: "valid",
        source: .explicitUserStatement
      )
    }
    #expect(throws: PersonalMemoryError.self) {
      _ = try PersonalMemoryRecord(
        scope: scope,
        kind: .fact,
        text: "\n",
        source: .explicitUserStatement
      )
    }
    #expect(throws: PersonalMemoryError.self) {
      _ = try PersonalMemoryRecord(
        scope: scope,
        kind: .fact,
        text: "valid",
        source: .explicitUserStatement,
        createdAt: Date(timeIntervalSince1970: 2),
        updatedAt: Date(timeIntervalSince1970: 1)
      )
    }
  }

  @Test
  func decodingCannotBypassValidation() throws {
    let invalidRecord = """
      {
        "scope": "mike.hex",
        "id": "memory-1",
        "kind": "fact",
        "text": "\\u0000",
        "source": "explicitUserStatement",
        "createdAt": 10,
        "updatedAt": 9,
        "isPinned": false
      }
      """

    #expect(throws: PersonalMemoryError.self) {
      _ = try JSONDecoder().decode(
        PersonalMemoryRecord.self,
        from: Data(invalidRecord.utf8)
      )
    }
  }
}
