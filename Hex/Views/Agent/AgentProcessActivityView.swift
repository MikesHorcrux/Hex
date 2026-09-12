import HexCore
import HexIPC
import SwiftUI

struct AgentProcessActivityView: View {
  let client: any HexGatewayProcessSessionClient
  let conversationID: UUID
  let open: () -> Void
  @State private var sessions: [ProcessSessionRecord] = []
  var body: some View {
    Group {
      if let latest = sessions.first {
        Button(action: open) {
          HStack {
            Image(systemName: "terminal")
            let active = sessions.filter { !$0.terminal }.count
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
      while !Task.isCancelled {
        do {
          sessions = try await client.processSession(
            .list(conversationID: conversationID, before: nil, limit: 50)
          ).sessions
        } catch { return }
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
      }
    }
  }
}
