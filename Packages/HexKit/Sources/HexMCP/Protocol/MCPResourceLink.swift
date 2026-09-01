public struct MCPResourceLink: Equatable, Sendable {
  public let name: String
  public let title: String?
  public let uri: String
  public let description: String?
  public let mimeType: String?
  public let size: Int64?

  public init(
    name: String,
    title: String? = nil,
    uri: String,
    description: String? = nil,
    mimeType: String? = nil,
    size: Int64? = nil
  ) {
    self.name = name
    self.title = title
    self.uri = uri
    self.description = description
    self.mimeType = mimeType
    self.size = size
  }
}
