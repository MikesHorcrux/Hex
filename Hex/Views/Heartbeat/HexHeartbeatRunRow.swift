import HexIPC
import SwiftUI

struct HexHeartbeatRunRow: View {
  let run: GatewayHeartbeatRun

  var body: some View {
    HStack(spacing: 9) {
      Image(systemName: HexHeartbeatRunPresentation.symbol(run))
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 3) {
        Text(run.scheduleName).lineLimit(1)
        Text(
          "\(run.dueAt.formatted(date: .abbreviated, time: .shortened)) · \(HexHeartbeatRunPresentation.status(run))"
        )
        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
    }
    .padding(.vertical, 3)
  }
}
