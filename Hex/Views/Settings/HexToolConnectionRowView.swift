import HexIPC
import SwiftUI

struct HexToolConnectionRowView: View {
  let status: GatewayToolServerStatus
  let isChecking: Bool
  let notice: String?
  let canCheck: Bool
  let onCheck: () -> Void
  let onStopWaiting: () -> Void

  private var presentation: HexToolConnectionPresentation {
    HexToolConnectionPresentation(status: status)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text(presentation.name)
            .font(.headline)
          Text(
            isChecking
              ? "Checking connection…" : notice == nil ? presentation.title : "Status not confirmed"
          )
          .font(.caption)
          .foregroundStyle(
            !isChecking && notice == nil && status.state == .ready
              ? HexBrandPalette.successInk : HexBrandPalette.mutedInk)
        }
        Spacer(minLength: 8)
        if isChecking {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Checking \(presentation.name)")
          Button("Stop waiting", action: onStopWaiting)
            .buttonStyle(.hexSecondaryAction)
            .help(
              "Stops waiting here; it does not cancel a shared connection attempt in Hex Agent.")
        } else {
          Button(presentation.actionTitle, action: onCheck)
            .buttonStyle(.hexSecondaryAction)
            .disabled(!canCheck)
            .accessibilityLabel("\(presentation.actionTitle): \(presentation.name)")
        }
      }
      if let detail = notice ?? presentation.detail {
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, 5)
  }
}
