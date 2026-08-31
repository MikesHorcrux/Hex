import Foundation

public struct PersonalMemoryRecord: Codable, Equatable, Sendable {
  public let id: PersonalMemoryID
  public let kind: PersonalMemoryKind
  public let text: String
  public let source: PersonalMemorySource
  public let createdAt: Date
  public let updatedAt: Date
  public let isPinned: Bool

  public init(
    id: PersonalMemoryID = PersonalMemoryID(),
    kind: PersonalMemoryKind,
    text: String,
    source: PersonalMemorySource,
    createdAt: Date = Date(),
    updatedAt: Date? = nil,
    isPinned: Bool = false
  ) throws {
    let resolvedUpdatedAt = updatedAt ?? createdAt
    guard
      !id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      id.rawValue.utf8.count <= 256,
      !id.rawValue.contains("\0")
    else {
      throw PersonalMemoryError.invalidIdentifier
    }
    guard
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.utf8.count <= 16_384,
      !text.contains("\0")
    else {
      throw PersonalMemoryError.invalidText
    }
    guard
      createdAt.timeIntervalSinceReferenceDate.isFinite,
      resolvedUpdatedAt.timeIntervalSinceReferenceDate.isFinite,
      createdAt <= resolvedUpdatedAt
    else {
      throw PersonalMemoryError.invalidTimestamp
    }

    self.id = id
    self.kind = kind
    self.text = text
    self.source = source
    self.createdAt = createdAt
    self.updatedAt = resolvedUpdatedAt
    self.isPinned = isPinned
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: container.decode(PersonalMemoryID.self, forKey: .id),
      kind: container.decode(PersonalMemoryKind.self, forKey: .kind),
      text: container.decode(String.self, forKey: .text),
      source: container.decode(PersonalMemorySource.self, forKey: .source),
      createdAt: container.decode(Date.self, forKey: .createdAt),
      updatedAt: container.decode(Date.self, forKey: .updatedAt),
      isPinned: container.decode(Bool.self, forKey: .isPinned)
    )
  }
}
