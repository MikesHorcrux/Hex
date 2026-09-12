import Foundation

public struct WebFetchRequest: Equatable, Sendable {
  public let url: URL
  public let method: WebRequestMethod
  public let body: Data?
  public let contentType: String?
  public let maximumResponseBytes: Int
  public let timeoutSeconds: Int

  public init(
    url: URL,
    method: WebRequestMethod = .get,
    body: Data? = nil,
    contentType: String? = nil,
    maximumResponseBytes: Int,
    timeoutSeconds: Int
  ) {
    self.url = url
    self.method = method
    self.body = body
    self.contentType = contentType
    self.maximumResponseBytes = maximumResponseBytes
    self.timeoutSeconds = timeoutSeconds
  }
}
