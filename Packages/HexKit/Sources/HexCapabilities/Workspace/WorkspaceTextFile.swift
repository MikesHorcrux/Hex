public struct WorkspaceTextFile: Codable, Equatable, Sendable {
  public let path: String
  public let content: String
  public let revision: String
  public let byteCount: Int

  public init(
    path: String,
    content: String,
    revision: String,
    byteCount: Int
  ) {
    self.path = path
    self.content = content
    self.revision = revision
    self.byteCount = byteCount
  }
}
