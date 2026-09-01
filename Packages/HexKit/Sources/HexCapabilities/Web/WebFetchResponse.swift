import Foundation

public struct WebFetchResponse: Equatable, Sendable {
  public let url: URL
  public let statusCode: Int
  public let contentType: String?
  public let body: Data
  public let isTruncated: Bool
  public let redirectURL: URL?

  public init(
    url: URL,
    statusCode: Int,
    contentType: String?,
    body: Data,
    isTruncated: Bool,
    redirectURL: URL? = nil
  ) {
    self.url = url
    self.statusCode = statusCode
    self.contentType = contentType
    self.body = body
    self.isTruncated = isTruncated
    self.redirectURL = redirectURL
  }
}
