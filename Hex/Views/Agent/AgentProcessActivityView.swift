import HexCore
import HexIPC
import SwiftUI

struct AgentProcessActivityView: View {
  let client: any HexGatewayProcessSessionClient
  let conversationID: UUID
  let open: () -> Void
  @State private var model = AgentProcessActivityModel()
  var body: some View {
    Group {
      if let latest = model.sessions.first {
        Button(action: open) {
          HStack {
            Image(systemName: "terminal")
            let active = model.sessions.filter { !$0.terminal }.count
            Text(
              active > 0
                ? "\(active) process\(active == 1 ? "" : "es") running"
                : "\(URL(fileURLWithPath: latest.executable).lastPathComponent) · \(latest.phase)")
            Spacer()
            Text("Output and changes").foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
          }.font(.caption).padding(10)
        }.buttonStyle(.plain).background(
          HexBrandPalette.coral.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
      }
    }.task(id: conversationID) {
      await model.observe(client: client, conversationID: conversationID)
    }
  }
}
