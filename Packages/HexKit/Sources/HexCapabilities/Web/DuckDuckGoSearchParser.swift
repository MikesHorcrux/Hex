import Foundation

enum DuckDuckGoSearchParser {
  static func parse(_ html: String, maximumResults: Int) throws -> [WebSearchResult] {
    let pattern =
      #"(?is)<a[^>]*class=[\"']result__a[\"'][^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>.*?<a[^>]*class=[\"']result__snippet[\"'][^>]*>(.*?)</a>"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
      throw WebToolError.searchResponseInvalid
    }
    let range = NSRange(html.startIndex..<html.endIndex, in: html)
    let matches = expression.matches(in: html, options: [], range: range)
    var results: [WebSearchResult] = []
    results.reserveCapacity(min(maximumResults, matches.count))
    for match in matches.prefix(maximumResults * 2) {
      guard
        let rawURL = capture(1, match: match, source: html),
        let rawTitle = capture(2, match: match, source: html),
        let rawSnippet = capture(3, match: match, source: html),
        let url = resultURL(from: rawURL)
      else {
        continue
      }
      results.append(
        WebSearchResult(
          title: HTMLTextSanitizer.text(from: rawTitle),
          url: url,
          snippet: HTMLTextSanitizer.text(from: rawSnippet)
        )
      )
      if results.count == maximumResults { break }
    }
    guard !results.isEmpty else {
      throw WebToolError.searchResponseInvalid
    }
    return results
  }

  private static func capture(
    _ index: Int,
    match: NSTextCheckingResult,
    source: String
  ) -> String? {
    let range = match.range(at: index)
    guard range.location != NSNotFound, let swiftRange = Range(range, in: source) else {
      return nil
    }
    return String(source[swiftRange])
  }

  private static func resultURL(from encodedValue: String) -> URL? {
    let decoded = HTMLTextSanitizer.decodeEntities(in: encodedValue)
    guard let initial = URL(string: decoded) else { return nil }
    let candidate: URL
    if initial.host?.hasSuffix("duckduckgo.com") == true,
      let components = URLComponents(url: initial, resolvingAgainstBaseURL: false),
      let redirected = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
      let redirectedURL = URL(string: redirected)
    {
      candidate = redirectedURL
    } else {
      candidate = initial
    }
    guard candidate.scheme?.lowercased() == "https", candidate.host != nil else {
      return nil
    }
    return candidate
  }
}
