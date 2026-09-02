import Foundation
import SwiftUI

struct MarkdownMessageView: View {
  let markdown: String
  private let parser = MarkdownParser()

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      ForEach(Array(parser.parse(markdown).enumerated()), id: \.offset) { _, block in
        rendered(block)
      }
    }
    .textSelection(.enabled)
  }

  @ViewBuilder
  private func rendered(_ block: MarkdownBlock) -> some View {
    switch block {
    case .heading(let level, let text):
      Text(inlineMarkdown(text))
        .font(font(forHeadingLevel: level))
        .fontWeight(.semibold)
        .padding(.top, level <= 2 ? 5 : 1)

    case .paragraph(let text):
      Text(inlineMarkdown(text))
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)

    case .unorderedListItem(let text):
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("•")
          .foregroundStyle(.secondary)
        Text(inlineMarkdown(text))
          .fixedSize(horizontal: false, vertical: true)
      }

    case .orderedListItem(let number, let text):
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("\(number).")
          .foregroundStyle(.secondary)
          .monospacedDigit()
        Text(inlineMarkdown(text))
          .fixedSize(horizontal: false, vertical: true)
      }

    case .codeBlock(let language, let code):
      VStack(alignment: .leading, spacing: 6) {
        if let language {
          Text(language.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        ScrollView(.horizontal) {
          Text(code)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: true, vertical: false)
        }
      }
      .padding(10)
      .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
      .overlay {
        RoundedRectangle(cornerRadius: 7)
          .strokeBorder(.separator.opacity(0.7))
      }

    case .quote(let text):
      HStack(alignment: .top, spacing: 9) {
        Capsule()
          .fill(Color.secondary.opacity(0.5))
          .frame(width: 3)
        Text(inlineMarkdown(text))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

    case .thematicBreak:
      Divider()
    }
  }

  private func inlineMarkdown(_ source: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
  }

  private func font(forHeadingLevel level: Int) -> Font {
    switch level {
    case 1:
      .title2
    case 2:
      .title3
    case 3:
      .headline
    default:
      .subheadline
    }
  }
}
