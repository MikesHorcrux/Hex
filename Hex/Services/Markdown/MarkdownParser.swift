import Foundation

nonisolated struct MarkdownParser: Sendable {
  func parse(_ source: String) -> [MarkdownBlock] {
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var blocks: [MarkdownBlock] = []
    var paragraphLines: [String] = []
    var codeLines: [String] = []
    var codeLanguage: String?
    var codeFence: String?

    func appendParagraph() {
      guard !paragraphLines.isEmpty else { return }
      let text = paragraphLines.joined(separator: " ")
      blocks.append(.paragraph(text))
      paragraphLines.removeAll(keepingCapacity: true)
    }

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if let activeFence = codeFence {
        if trimmed.hasPrefix(activeFence) {
          blocks.append(
            .codeBlock(
              language: codeLanguage,
              code: codeLines.joined(separator: "\n")
            )
          )
          codeLines.removeAll(keepingCapacity: true)
          codeLanguage = nil
          codeFence = nil
        } else {
          codeLines.append(line)
        }
        continue
      }

      if let fence = Self.fence(in: trimmed) {
        appendParagraph()
        codeFence = fence.marker
        codeLanguage = fence.language
        continue
      }

      guard !trimmed.isEmpty else {
        appendParagraph()
        continue
      }

      if let heading = Self.heading(in: trimmed) {
        appendParagraph()
        blocks.append(.heading(level: heading.level, text: heading.text))
      } else if Self.isThematicBreak(trimmed) {
        appendParagraph()
        blocks.append(.thematicBreak)
      } else if let quote = Self.quote(in: trimmed) {
        appendParagraph()
        blocks.append(.quote(quote))
      } else if let item = Self.unorderedListItem(in: trimmed) {
        appendParagraph()
        blocks.append(.unorderedListItem(item))
      } else if let item = Self.orderedListItem(in: trimmed) {
        appendParagraph()
        blocks.append(.orderedListItem(number: item.number, text: item.text))
      } else {
        paragraphLines.append(trimmed)
      }
    }

    appendParagraph()
    if codeFence != nil {
      blocks.append(
        .codeBlock(
          language: codeLanguage,
          code: codeLines.joined(separator: "\n")
        )
      )
    }
    return blocks
  }

  private static func fence(in line: String) -> (marker: String, language: String?)? {
    let marker: String
    if line.hasPrefix("```") {
      marker = "```"
    } else if line.hasPrefix("~~~") {
      marker = "~~~"
    } else {
      return nil
    }
    let language = String(line.dropFirst(marker.count))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (marker, language.isEmpty ? nil : language)
  }

  private static func heading(in line: String) -> (level: Int, text: String)? {
    let hashes = line.prefix { $0 == "#" }
    guard (1...6).contains(hashes.count) else { return nil }
    let remainder = line.dropFirst(hashes.count)
    guard remainder.first == " " else { return nil }
    let text = remainder.dropFirst().trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : (hashes.count, text)
  }

  private static func quote(in line: String) -> String? {
    guard line.first == ">" else { return nil }
    let text = line.dropFirst().trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : text
  }

  private static func unorderedListItem(in line: String) -> String? {
    guard line.count >= 2 else { return nil }
    let prefix = line.prefix(2)
    guard prefix == "- " || prefix == "* " || prefix == "+ " else { return nil }
    let text = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : text
  }

  private static func orderedListItem(in line: String) -> (number: Int, text: String)? {
    guard let punctuation = line.firstIndex(of: ".") else { return nil }
    let numberText = line[..<punctuation]
    guard !numberText.isEmpty, numberText.allSatisfy(\.isNumber), let number = Int(numberText)
    else {
      return nil
    }
    let afterPunctuation = line.index(after: punctuation)
    guard afterPunctuation < line.endIndex, line[afterPunctuation] == " " else { return nil }
    let textStart = line.index(after: afterPunctuation)
    let text = line[textStart...].trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : (number, text)
  }

  private static func isThematicBreak(_ line: String) -> Bool {
    ["---", "***", "___"].contains(line)
  }
}
