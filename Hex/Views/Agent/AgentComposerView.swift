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
        .frame(minHeight: 74, maxHeight: 150)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
          RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.secondary.opacity(0.22))
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
            .buttonStyle(.hexSecondaryAction)
            .keyboardShortcut(".", modifiers: [.command])
            .accessibilityIdentifier("cancelRunButton")
        }

        Button(action: onSend) {
          Label("Send", systemImage: "arrow.up.circle.fill")
        }
        .buttonStyle(.hexPrimaryAction)
        .keyboardShortcut(.return, modifiers: [.command])
        .disabled(!canSend)
        .accessibilityIdentifier("sendPromptButton")
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 10)
    .padding(.bottom, 16)
    .background(.thinMaterial)
  }
}
