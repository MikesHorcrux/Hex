import HexIPC
import SwiftUI

struct HexBuildDetailsView: View {
  let gatewaySummary: String

  var body: some View {
    Section("Build & connection") {
      LabeledContent("App location") {
        Text(Bundle.main.bundleURL.path)
          .textSelection(.enabled)
          .font(.caption.monospaced())
      }
      LabeledContent("App code build") {
        Text(
          (GatewayExecutableIdentity.runningImageID(named: "Hex.debug.dylib")
            ?? GatewayExecutableIdentity.runningExecutableID)?.uuidString ?? "Unavailable"
        )
        .textSelection(.enabled)
        .font(.caption.monospaced())
      }
      Text(gatewaySummary)
        .font(.caption)
        .textSelection(.enabled)
      Text(
        "The connected agent must match the helper bundled with this app. These build IDs are not git commit IDs."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}
