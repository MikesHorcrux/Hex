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
    protectedFolders
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

      if model.isRequestingScreenControl {
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
      } else {
        Text("Hex will install screen control first, then ask macOS for the access it needs.")
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
        if model.screenControlPermissionsGranted == true {
          Button("Verify Again") {
            Task {
              await model.refreshScreenControlPermissions()
            }
          }
          .buttonStyle(.hexSecondaryAction)
        } else {
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
      .disabled(model.isRequestingScreenControl)
    }
    .padding(.vertical, 6)
  }

  private var protectedFolders: some View {
    VStack(alignment: .leading, spacing: 9) {
      capabilityHeader(
        title: "Protected folders",
        systemImage: "internaldrive",
        status: "Manual setup",
        tint: HexBrandPalette.apricot
      )

      Text(
        "For files macOS protects, add Hex Agent to Full Disk Access. Hex cannot approve this for you."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      HStack(spacing: 8) {
        Button("Show Hex Agent") {
          revealResidentAgent()
        }
        .buttonStyle(.hexSecondaryAction)
        Button("Open Full Disk Access") {
          openPrivacySettings("Privacy_AllFiles")
        }
        .buttonStyle(.hexSecondaryAction)
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

  private func revealResidentAgent() {
    let url = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Resources/HexGateway.app", isDirectory: true)
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  private func openPrivacySettings(_ anchor: String) {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
      )
    else {
      return
    }
    openURL(url)
  }
}
