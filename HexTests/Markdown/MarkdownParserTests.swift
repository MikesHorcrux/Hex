import Testing

@testable import Hex

@Suite("Markdown parser")
struct MarkdownParserTests {
  @Test
  func separatesCommonAgentResponseBlocks() {
    let source = """
      # Result

      A **useful** response across
      two source lines.

      - first item
      2. second item
      > keep this boundary

      ```swift
      let answer = 42
      ```
      """

    let blocks = MarkdownParser().parse(source)

    #expect(
      blocks == [
        .heading(level: 1, text: "Result"),
        .paragraph("A **useful** response across two source lines."),
        .unorderedListItem("first item"),
        .orderedListItem(number: 2, text: "second item"),
        .quote("keep this boundary"),
        .codeBlock(language: "swift", code: "let answer = 42"),
      ]
    )
  }

  @Test
  func preservesAnUnclosedCodeFenceAsCode() {
    let blocks = MarkdownParser().parse("```\ncommand --flag")

    #expect(blocks == [.codeBlock(language: nil, code: "command --flag")])
  }
}
