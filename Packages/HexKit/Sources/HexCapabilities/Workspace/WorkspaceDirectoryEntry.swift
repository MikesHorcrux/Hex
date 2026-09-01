public struct WorkspaceDirectoryEntry: Codable, Equatable, Sendable {
  public let path: String
  public let name: String
  public let kind: WorkspaceEntryKind
  public let byteCount: Int?

  public init(
    path: String,
    name: String,
    kind: WorkspaceEntryKind,
    byteCount: Int?
  ) {
    self.path = path
    self.name = name
    self.kind = kind
    self.byteCount = byteCount
  }
}
