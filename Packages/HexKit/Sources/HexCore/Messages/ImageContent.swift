import Foundation

public struct ImageContent: Codable, Equatable, Sendable {
  public let sourceURL: URL
  public let mediaType: String

  public init(sourceURL: URL, mediaType: String) {
    self.sourceURL = sourceURL
    self.mediaType = mediaType
  }
}
