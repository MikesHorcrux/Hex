public struct WorkspaceSearchMatch: Codable, Equatable, Sendable {
  public let path: String
  public let line: Int
  public let text: String
  public let isTruncated: Bool

  public init(
    path: String,
    line: Int,
    text: String,
    isTruncated: Bool
  ) {
    self.path = path
    self.line = line
    self.text = text
    self.isTruncated = isTruncated
  }
}
