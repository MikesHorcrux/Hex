import AppKit
import HexIPC
import SwiftUI

struct HexProtectedFoldersPermissionView: View {
  @Bindable var model: HexFolderAccessModel
  @Environment(\.openURL) private var openURL

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      Label("Protected folders", systemImage: "internaldrive").font(.headline)
      Text(
        "Check that Hex Agent can read your saved workspace. This check does not cover writes or other folders. For protected files, you may need to add Hex Agent in Full Disk Access."
      )
      .font(.caption).foregroundStyle(.secondary)
      if model.isChecking {
        ProgressView("Checking saved workspace access…").controlSize(.small)
      } else if let status = model.status {
        Label(
          accessTitle(status.access),
          systemImage: status.access == .readable ? "checkmark.circle" : "exclamationmark.triangle"
        )
        .foregroundStyle(status.access == .readable ? HexBrandPalette.successInk : .orange)
        Text(status.directory.path).font(.caption.monospaced()).textSelection(.enabled)
        if status.access == .denied {
          Text(
            "macOS or folder permissions denied this read. Check Files & Folders or Full Disk Access for Hex Agent and the folder’s sharing permissions, then verify again."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }
      if let message = model.message {
        Text(message).font(.caption).foregroundStyle(.orange)
      }
      HStack {
        Button(model.hasRequestedCheck ? "Verify Folder Access" : "Check Saved Workspace") {
          Task { await model.refresh() }
        }
        .disabled(model.isChecking)
        .accessibilityIdentifier("verifyFolderAccess")
        Button("Show Hex Agent") { NSWorkspace.shared.activateFileViewerSelecting([agentBundle]) }
        Button("Open Full Disk Access") {
          if let url = URL(
            string:
              "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
          ) {
            openURL(url)
          }
        }
      }
      .buttonStyle(.hexSecondaryAction)
      DisclosureGroup("Hex Agent location") {
        Text(agentBundle.path).font(.caption2.monospaced()).textSelection(.enabled)
      }
    }
    .padding(.vertical, 6)
  }

  private var agentBundle: URL {
    model.status?.agentBundle
      ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/HexGateway.app")
  }

  private func accessTitle(_ access: GatewayFolderAccessMode) -> String {
    switch access {
    case .readable: "Saved workspace can be read"
    case .denied: "Saved workspace access denied"
    case .unavailable: "Saved workspace unavailable — check that the folder still exists"
    }
  }
}
