import HexCore
import SwiftUI

struct AgentProcessDetailsView: View {
  let session: ProcessSessionRecord
  let output: Data
  let omittedBytes: Int64
  let sending: Bool
  let hasPendingCommand: Bool
  @Binding var draft: String
  let readFromStart: () -> Void
  let send: (ProcessSessionCommandAction) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(([session.executable] + session.arguments).joined(separator: " "))
        .font(.caption.monospaced())
        .lineLimit(3)
        .textSelection(.enabled)
      HStack {
        Text(session.phase.capitalized)
        if let code = session.exitCode { Text("Exit \(code)") }
        if let signal = session.signal { Text("Signal \(signal)") }
        if session.terminal {
          Text(session.cleanupConfirmed ? "Group cleanup confirmed" : "Cleanup unconfirmed")
        }
      }
      .font(.caption)
      .foregroundStyle(HexBrandPalette.mutedInk)
      if !session.explanation.isEmpty {
        Text(session.explanation)
          .font(.caption)
          .foregroundStyle(HexBrandPalette.warningInk)
      }
      if omittedBytes > 0 {
        HStack {
          Text("Showing the latest 64 KiB. Earlier output remains saved.").font(.caption)
          Button("Read from start", action: readFromStart).buttonStyle(.link)
        }
      }
      HexCodeScrollView { Text(String(decoding: output, as: UTF8.self)) }
      AgentProcessControlsView(
        terminal: session.terminal, sending: sending, hasPendingCommand: hasPendingCommand,
        draft: $draft, send: send)
    }
  }
}
