import Foundation

public struct PersonalMemoryQuery: Equatable, Sendable {
  public let scope: PersonalMemoryScope
  public let text: String?
  public let kinds: Set<PersonalMemoryKind>
  public let limit: Int

  public init(
    scope: PersonalMemoryScope,
    text: String? = nil,
    kinds: Set<PersonalMemoryKind> = [],
    limit: Int
  ) throws {
    guard (1...256).contains(limit) else {
      throw PersonalMemoryStoreError.invalidQuery
    }
    if let text {
      guard
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        text.utf8.count <= 4_096,
        text.split(whereSeparator: \Character.isWhitespace).count <= 32,
        !text.contains("\0")
      else {
        throw PersonalMemoryStoreError.invalidQuery
      }
    }
    self.scope = scope
    self.text = text
    self.kinds = kinds
    self.limit = limit
  }
}
