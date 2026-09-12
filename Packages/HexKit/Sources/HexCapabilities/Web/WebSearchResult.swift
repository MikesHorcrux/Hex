import Foundation

public struct WebSearchResult: Equatable, Sendable {
  public let title: String
  public let url: URL
  public let snippet: String

  public init(title: String, url: URL, snippet: String) {
    self.title = title
    self.url = url
    self.snippet = snippet
  }
}
