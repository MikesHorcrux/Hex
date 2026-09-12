import Foundation

enum WebContentExtractor {
  static func text(from response: WebFetchResponse) throws -> String {
    let mediaType = response.contentType?
      .split(separator: ";", maxSplits: 1)
      .first?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard isSupported(mediaType) else {
      throw WebToolError.unsupportedContentType
    }
    guard
      let decoded = String(data: response.body, encoding: .utf8)
        ?? String(data: response.body, encoding: .isoLatin1)
    else {
      throw WebToolError.invalidTextEncoding
    }
    if mediaType == "text/html" || mediaType == "application/xhtml+xml" {
      return HTMLTextSanitizer.text(from: decoded)
    }
    return decoded
  }

  private static func isSupported(_ mediaType: String?) -> Bool {
    guard let mediaType else { return true }
    return mediaType.hasPrefix("text/")
      || mediaType == "application/json"
      || mediaType == "application/xml"
      || mediaType == "application/xhtml+xml"
      || mediaType == "application/rss+xml"
      || mediaType == "application/atom+xml"
  }
}
