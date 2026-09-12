import SwiftUI

struct AgentStreamingTextView: View, Equatable {
  let text: String

  var body: some View {
    // One growing, multi-screen Text repeatedly typesets every previous line. Bounded, stable
    // prefixes let SwiftUI keep their layout while only the final chunk changes.
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(AgentStreamingTextLayout.chunks(text).enumerated()), id: \.offset) { _, chunk in
        Text(verbatim: chunk)
          .font(.system(size: 15))
          .lineSpacing(3)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .textSelection(.enabled)
  }
}
