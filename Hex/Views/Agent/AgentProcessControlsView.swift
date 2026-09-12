import HexCore
import SwiftUI

struct AgentProcessControlsView: View {
  let terminal: Bool
  let sending: Bool
  let hasPendingCommand: Bool
  @Binding var draft: String
  let send: (ProcessSessionCommandAction) -> Void

  var body: some View {
    VStack(spacing: 10) {
      HStack {
        TextField("Input (Send adds a newline)", text: $draft)
          .textFieldStyle(.roundedBorder)
          .onSubmit { send(.input) }
        Button("Send") { send(.input) }
          .buttonStyle(.hexPrimaryAction)
      }
      .disabled(terminal || sending || hasPendingCommand)
      HStack {
        Button("Interrupt") { send(.interrupt) }
          .disabled(hasPendingCommand)
        Button("Send EOF") { send(.eof) }
          .disabled(hasPendingCommand)
        Spacer()
        Button("Stop process", role: .destructive) { send(.stop) }
          .buttonStyle(.bordered)
      }
      .buttonStyle(.hexSecondaryAction)
      .disabled(terminal || sending)
    }
  }
}
