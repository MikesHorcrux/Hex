public struct WorkspaceFileChangePreview: Codable, Sendable, Identifiable {
  public let id: String
  public let path: String
  public let before: String?
  public let after: String?
  public let truncated: Bool
  public init(id: String, path: String, before: String?, after: String?, truncated: Bool) {
    self.id = id
    self.path = path
    self.before = before
    self.after = after
    self.truncated = truncated
  }
}
