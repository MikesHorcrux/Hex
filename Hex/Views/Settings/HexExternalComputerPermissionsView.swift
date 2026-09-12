import AppKit
import HexIPC
import HexMCP
import Observation
import SwiftUI

struct HexExternalComputerPermissionsView: View {
  @Bindable var model: HexResidentSetupModel
  @Environment(\.openURL) private var openURL

  var body: some View {
    browserControl
    screenControl
    HexProtectedFoldersPermissionView(model: model.folderAccess)
  }

  private var browserControl: some View {
    VStack(alignment: .leading, spacing: 8) {
      capabilityHeader(
        title: "Browser control",
        systemImage: "globe",
        status: browserStatusTitle,
        tint: browserStatusTint
      )

      if model.isInstallingPlaywright {
        ProgressView("Downloading and checking browser control…")
          .controlSize(.small)
      } else if model.playwrightAvailability == .ready {
        Text(browserDetail)
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Text("Enable Browser control in Tools and Hex will download everything it needs.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 6)
  }

  private var screenControl: some View {
    VStack(alignment: .leading, spacing: 9) {
      capabilityHeader(
        title: "Screen control",
        systemImage: "eye",
        status: screenStatusTitle,
        tint: screenStatusTint
      )

      if model.isRequestingScreenControl || model.isCheckingScreenControl {
        ProgressView("Checking screen control…")
          .controlSize(.small)
      } else if let status = model.screenControlPermissionStatus {
        permissionStatusLabel("Accessibility", isGranted: status.accessibilityGranted)
        permissionStatusLabel("Screen Recording", isGranted: status.screenRecordingGranted)
        if !status.isGranted {
          Text("Allow the missing items in System Settings, then return and verify again.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else if let error = model.screenControlPermissionError {
        Text("Could not verify screen permissions. \(error)")
          .font(.caption).foregroundStyle(.orange)
      } else {
        Text(
          model.peekabooAvailability == .ready
            ? "Screen control is installed. Verify its Mac permissions, or request access if needed."
            : "Hex will install screen control first, then ask macOS for the access it needs."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      if model.screenSetupStatus == .disabled {
        Text("Screen control is off. Enable it in Tools and save before asking Hex to use it.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if model.screenSetupStatus == .needsSave {
        Text("Save your tool settings to apply this choice. Mac permissions are separate.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 8) {
        if model.peekabooAvailability == .ready {
          Button("Verify Again") {
            Task {
              await model.refreshScreenControlPermissions()
            }
          }
          .buttonStyle(.hexSecondaryAction)
        }
        if model.screenControlPermissionsGranted != true {
          Button("Allow Screen Permissions") {
            model.requestScreenControlPermissions()
          }
          .buttonStyle(.hexPrimaryAction)
        }

        if model.screenControlPermissionStatus?.accessibilityGranted == false {
          Button("Accessibility Settings") {
            openPrivacySettings("Privacy_Accessibility")
          }
          .buttonStyle(.hexSecondaryAction)
        }
        if model.screenControlPermissionStatus?.screenRecordingGranted == false {
          Button("Screen Recording Settings") {
            openPrivacySettings("Privacy_ScreenCapture")
          }
          .buttonStyle(.hexSecondaryAction)
        }
      }
      .disabled(model.isRequestingScreenControl || model.isCheckingScreenControl)
      if let bundle = model.screenControlBundleURL, model.peekabooAvailability == .ready {
        Text("Screen permissions belong to Hex’s screen helper (PeekabooCLI), not the chat window.")
          .font(.caption).foregroundStyle(.secondary)
        Button("Show Screen Helper") { NSWorkspace.shared.activateFileViewerSelecting([bundle]) }
          .buttonStyle(.hexSecondaryAction)
        DisclosureGroup("Screen helper location") {
          Text(bundle.path).font(.caption2.monospaced()).textSelection(.enabled)
        }
      }
    }
    .padding(.vertical, 6)
  }

  private func capabilityHeader(
    title: String,
    systemImage: String,
    status: String,
    tint: Color
  ) -> some View {
    HStack(spacing: 9) {
      Label(title, systemImage: systemImage)
        .font(.headline)
      Spacer()
      Text(status)
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(tint.opacity(0.11), in: Capsule())
    }
  }

  private var browserStatusTitle: String {
    model.browserSetupStatus.title
  }

  private var browserDetail: String {
    switch model.browserSetupStatus {
    case .disabled:
      "Browser components are installed, but browser control is off. Enable it in Tools and save."
    case .needsSave:
      "Browser components are installed. Save your tool settings to apply this choice."
    default:
      "Browser components are installed. Browser control does not need a separate Mac privacy permission."
    }
  }

  private var browserStatusTint: Color {
    if model.isInstallingPlaywright {
      HexBrandPalette.coral
    } else if model.browserSetupStatus == .installed {
      HexBrandPalette.successInk
    } else {
      HexBrandPalette.mutedInk
    }
  }

  private var screenStatusTitle: String {
    model.screenSetupStatus.title
  }

  private var screenStatusTint: Color {
    if model.isRequestingScreenControl {
      HexBrandPalette.coral
    } else if model.screenSetupStatus == .permissionsGranted {
      HexBrandPalette.successInk
    } else if model.screenSetupStatus == .needsApproval {
      .orange
    } else {
      HexBrandPalette.mutedInk
    }
  }

  private func permissionStatusLabel(_ name: String, isGranted: Bool) -> some View {
    Label(
      "\(name): \(isGranted ? "Granted" : "Needs approval")",
      systemImage: isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    )
    .font(.caption)
    .foregroundStyle(isGranted ? HexBrandPalette.successInk : .orange)
  }

  private func openPrivacySettings(_ anchor: String) {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)"
      )
    else {
      return
    }
    openURL(url)
  }
}
