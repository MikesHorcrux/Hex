import Testing

@testable import Hex

@Suite("Bounded Markdown list layout")
struct MarkdownLayoutTests {
  @Test
  func longNumberedAnswerUsesBoundedLayoutsWithoutLosingLinesOrNumbering() {
    let source = (1...500).map {
      MarkdownBlock.orderedListItem(number: $0, text: "Hex keeps working")
    }
    let expected = (1...500).map { "\($0). Hex keeps working" }.joined(separator: "\n")
    let paragraphs = MarkdownLayout.blocks(source).compactMap { block -> String? in
      guard case .paragraph(let text) = block else { return nil }
      return text
    }
    #expect(paragraphs.count == 16)
    #expect(paragraphs.allSatisfy { $0.split(separator: "\n").count <= 32 })
    #expect(paragraphs.joined(separator: "\n") == expected)
  }

  @Test
  func groupingPreservesInlineMarkupAndNonListBoundaries() {
    let source: [MarkdownBlock] = [
      .heading(level: 2, text: "Result"),
      .unorderedListItem("**first**"),
      .orderedListItem(number: 7, text: "[second](https://example.com)"),
      .codeBlock(language: "swift", code: "let count = 7"),
      .orderedListItem(number: 9, text: "last"), .quote("Keep this"), .thematicBreak,
      .paragraph("Finished"),
    ]
    #expect(
      MarkdownLayout.blocks(source) == [
        .heading(level: 2, text: "Result"),
        .paragraph("• **first**\n7. [second](https://example.com)"),
        .codeBlock(language: "swift", code: "let count = 7"),
        .paragraph("9. last"), .quote("Keep this"), .thematicBreak, .paragraph("Finished"),
      ])
    #expect(MarkdownLayout.blocks([]).isEmpty)
  }
}
