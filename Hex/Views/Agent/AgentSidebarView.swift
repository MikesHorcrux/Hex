import Observation
import SwiftUI

struct AgentSidebarView: View {
  @Bindable var model: AgentWorkspaceModel

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Text("HEX")
          .font(.system(size: 28, weight: .bold, design: .rounded))
          .tracking(2)
        Text("First-agent control surface")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Divider()

      VStack(alignment: .leading, spacing: 10) {
        Label("Gateway", systemImage: "bolt.horizontal.circle")
          .font(.headline)
        HStack(spacing: 8) {
          Circle()
            .fill(connectionColor)
            .frame(width: 9, height: 9)
          Text(model.connectionState.label)
            .font(.subheadline.weight(.medium))
          Spacer()
          if model.connectionState == .connecting {
            ProgressView()
              .controlSize(.small)
          } else if model.connectionState == .connected {
            Button("Disconnect", action: model.disconnectFromControl)
              .buttonStyle(.hexSecondaryAction)
              .controlSize(.small)
          } else {
            Button("Connect", action: model.connectFromControl)
              .buttonStyle(.hexPrimaryAction)
              .controlSize(.small)
          }
        }
        Text(model.gatewaySummary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }

      Divider()

      VStack(alignment: .leading, spacing: 9) {
        Label("Model", systemImage: "cpu")
          .font(.headline)
        TextField("Model ID", text: $model.modelID)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("modelIDField")
        Text("The gateway composition supplies the provider and credentials.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Divider()

      VStack(alignment: .leading, spacing: 9) {
        Label("Current run", systemImage: "waveform.path.ecg")
          .font(.headline)
        Text(model.runSummary)
          .font(.subheadline.weight(.medium))
        Text(model.activity)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 12)

      VStack(alignment: .leading, spacing: 5) {
        Label("Permissioned by design", systemImage: "checkmark.shield")
          .font(.subheadline.weight(.medium))
        Text("Tool requests pause here until you choose what Hex may do.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  private var connectionColor: Color {
    switch model.connectionState {
    case .connected:
      .green
    case .connecting:
      .orange
    case .disconnected:
      .secondary
    }
  }
}
