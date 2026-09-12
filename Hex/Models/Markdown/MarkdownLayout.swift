/// Keep list layout bounded: neither one nested stack per line nor one unbounded text layout.
/// This is a presentation transform only; original transcript text and all numbering survive.
nonisolated enum MarkdownLayout {
  static func blocks(_ source: [MarkdownBlock]) -> [MarkdownBlock] {
    var result: [MarkdownBlock] = []
    var listLines: [String] = []
    for block in source {
      switch block {
      case .orderedListItem(let number, let text):
        listLines.append("\(number). \(text)")
      case .unorderedListItem(let text):
        listLines.append("• \(text)")
      default:
        if !listLines.isEmpty {
          result.append(.paragraph(listLines.joined(separator: "\n")))
          listLines.removeAll(keepingCapacity: true)
        }
        result.append(block)
      }
      if listLines.count == 32 {
        result.append(.paragraph(listLines.joined(separator: "\n")))
        listLines.removeAll(keepingCapacity: true)
      }
    }
    if !listLines.isEmpty { result.append(.paragraph(listLines.joined(separator: "\n"))) }
    return result
  }
}
