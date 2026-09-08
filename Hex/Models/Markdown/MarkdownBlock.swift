nonisolated enum MarkdownBlock: Equatable, Sendable {
  case heading(level: Int, text: String)
  case paragraph(String)
  case unorderedListItem(String)
  case orderedListItem(number: Int, text: String)
  case codeBlock(language: String?, code: String)
  case quote(String)
  case thematicBreak
}
