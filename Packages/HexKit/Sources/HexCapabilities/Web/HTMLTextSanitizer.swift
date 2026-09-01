import Foundation

enum HTMLTextSanitizer {
  static func text(from html: String) -> String {
    var value = replacing(
      #"(?is)<(script|style|noscript)[^>]*>.*?</\1>"#,
      in: html,
      with: " "
    )
    value = replacing(#"(?i)<\s*(br|/p|/div|/li|/h[1-6])\b[^>]*>"#, in: value, with: "\n")
    value = replacing(#"(?s)<[^>]+>"#, in: value, with: "")
    value = decodeEntities(in: value)
    return
      value
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { line in
        line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
      }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
  }

  static func decodeEntities(in value: String) -> String {
    var result = ""
    var index = value.startIndex
    while index < value.endIndex {
      guard value[index] == "&",
        let semicolon = value[index...].firstIndex(of: ";"),
        value.distance(from: index, to: semicolon) <= 12
      else {
        result.append(value[index])
        index = value.index(after: index)
        continue
      }
      let entityStart = value.index(after: index)
      let entity = String(value[entityStart..<semicolon])
      if let decoded = decodedEntity(entity) {
        result.append(decoded)
        index = value.index(after: semicolon)
      } else {
        result.append(value[index])
        index = value.index(after: index)
      }
    }
    return result
  }

  private static func replacing(
    _ pattern: String,
    in value: String,
    with replacement: String
  ) -> String {
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
      return value
    }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return expression.stringByReplacingMatches(
      in: value,
      options: [],
      range: range,
      withTemplate: replacement
    )
  }

  private static func decodedEntity(_ entity: String) -> Character? {
    let named: [String: Character] = [
      "amp": "&",
      "apos": "'",
      "gt": ">",
      "lt": "<",
      "nbsp": " ",
      "quot": "\"",
      "#39": "'",
      "#x27": "'",
    ]
    if let value = named[entity.lowercased()] {
      return value
    }
    let scalarValue: UInt32?
    if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
      scalarValue = UInt32(entity.dropFirst(2), radix: 16)
    } else if entity.hasPrefix("#") {
      scalarValue = UInt32(entity.dropFirst())
    } else {
      scalarValue = nil
    }
    guard let scalarValue, let scalar = UnicodeScalar(scalarValue) else {
      return nil
    }
    return Character(scalar)
  }
}
