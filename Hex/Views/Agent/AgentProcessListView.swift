import HexCore
import SwiftUI

struct AgentProcessListView: View {
  let sessions: [ProcessSessionRecord]
  @Binding var selection: UUID?

  var body: some View {
    List(selection: $selection) {
      ForEach(sessions) { session in
        VStack(alignment: .leading, spacing: 4) {
          Text(URL(fileURLWithPath: session.executable).lastPathComponent)
            .fontWeight(.medium)
          Text(session.phase + (session.retained ? " · retained" : ""))
            .font(.caption)
            .foregroundStyle(HexBrandPalette.mutedInk)
        }
        .tag(session.id)
      }
    }
    .frame(width: 180)
  }
}
