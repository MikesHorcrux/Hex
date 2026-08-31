public struct MCPEmbeddedResource: Equatable, Sendable {
  public let uri: String
  public let mimeType: String?
  public let text: String?
  public let blob: String?

  public init(
    uri: String,
    mimeType: String? = nil,
    text: String? = nil,
    blob: String? = nil
  ) {
    self.uri = uri
    self.mimeType = mimeType
    self.text = text
    self.blob = blob
  }
}
