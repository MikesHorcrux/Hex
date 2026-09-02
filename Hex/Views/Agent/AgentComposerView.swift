import SwiftUI

struct AgentComposerView: View {
  @Binding var draft: String
  let canSend: Bool
  let isRunning: Bool
  let onSend: () -> Void
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      TextEditor(text: $draft)
        .font(.body)
        .scrollContentBackground(.hidden)
        .padding(8)
        .frame(minHeight: 58, maxHeight: 130)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(.separator)
        }
        .accessibilityIdentifier("promptComposer")

      HStack {
        Text(
          isRunning
            ? "Hex is working. Tool requests will pause for your approval."
            : "Conversations are saved locally on this Mac."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)

        Spacer()

        if isRunning {
          Button("Cancel", action: onCancel)
            .buttonStyle(.bordered)
            .keyboardShortcut(".", modifiers: [.command])
            .accessibilityIdentifier("cancelRunButton")
        }

        Button(action: onSend) {
          Label("Send", systemImage: "arrow.up")
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.return, modifiers: [.command])
        .disabled(!canSend)
        .accessibilityIdentifier("sendPromptButton")
      }
    }
    .padding(.horizontal, 18)
    .padding(.top, 10)
    .padding(.bottom, 16)
    .background(.bar)
  }
}
