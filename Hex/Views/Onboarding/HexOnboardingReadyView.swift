import HexCore
import Observation
import SwiftUI

struct HexOnboardingReadyView: View {
  @Bindable var residentSetup: HexResidentSetupModel
  @Bindable var startAtLogin: HexStartAtLoginModel

  var body: some View {
    ZStack {
      HexBrandBackdrop()

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
              heroCopy
                .frame(maxWidth: 330, alignment: .leading)
              Spacer(minLength: 0)
              HexMascotView(size: 190)
            }

            VStack(alignment: .leading, spacing: 10) {
              HexMascotView(size: 155)
                .frame(maxWidth: .infinity)
              heroCopy
            }
          }

          setupCard
        }
        .frame(maxWidth: 620)
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
      }
    }
    .task {
      await startAtLogin.refresh()
    }
  }

  private var heroCopy: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text("WELCOME\nTO THE\nFLOCK.")
        .font(.system(size: 48, weight: .black, design: .default).width(.condensed))
        .lineSpacing(-6)
        .foregroundStyle(HexBrandPalette.cream)
        .accessibilityAddTraits(.isHeader)

      VStack(alignment: .leading, spacing: 5) {
        Text("YOUR SETUP IS SAVED.")
          .font(.headline.weight(.black))
          .tracking(0.8)

        Text("Start a conversation to verify the model and tools with something real.")
          .font(.callout.weight(.medium))
          .fixedSize(horizontal: false, vertical: true)
      }
      .foregroundStyle(HexBrandPalette.deepPlum)
      .padding(10)
      .background(
        HexBrandPalette.cream.opacity(0.92),
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
    }
  }

  private var setupCard: some View {
    VStack(alignment: .leading, spacing: 13) {
      Text("SETUP SNAPSHOT")
        .font(.caption.weight(.black))
        .tracking(1.2)
        .foregroundStyle(HexBrandPalette.coralPressed)

      setupRow("Model", value: residentSetup.modelID, systemImage: "cpu")
      setupRow("Workspace", value: residentSetup.workspaceDisplayName, systemImage: "folder.fill")
      setupRow(
        "Tool approvals",
        value: residentSetup.authorizationMode.permissionTitle,
        systemImage: residentSetup.authorizationMode.permissionSymbol
      )

      Divider()
        .overlay(HexBrandPalette.deepPlum.opacity(0.12))

      HStack(spacing: 10) {
        Image(systemName: "bolt.horizontal.circle.fill")
          .foregroundStyle(availabilityTint)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text("Always-on agent")
            .font(.callout.weight(.semibold))
            .foregroundStyle(HexBrandPalette.deepPlum)
          Text(startAtLogin.status.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(availabilityTint)
        }
        Spacer(minLength: 10)

        if startAtLogin.isAvailable {
          Button(startAtLogin.buttonTitle) {
            startAtLogin.toggle()
          }
          .buttonStyle(.hexSecondaryAction)
          .disabled(!startAtLogin.canChange)
        }
      }

      if startAtLogin.status == .requiresApproval {
        Button("Open Login Items Settings") {
          Task {
            await startAtLogin.openLoginItemsSettings()
          }
        }
        .buttonStyle(.hexSecondaryAction)
      }

      if let readinessMessage = startAtLogin.readinessMessage, !startAtLogin.isAvailable {
        HexInlineNoticeView(
          message: readinessMessage,
          systemImage: "exclamationmark.triangle.fill",
          tint: .orange,
          foreground: HexBrandPalette.deepPlum
        )
      }

      if let message = startAtLogin.message {
        HexInlineNoticeView(
          message: message,
          systemImage: "exclamationmark.triangle.fill",
          tint: .orange,
          foreground: HexBrandPalette.deepPlum
        )
      }

      HexInlineNoticeView(
        message: "You can revisit every choice in Settings.",
        systemImage: "checkmark.circle.fill",
        tint: HexBrandPalette.successOnCream,
        foreground: HexBrandPalette.deepPlum
      )
    }
    .padding(18)
    .background(
      HexBrandPalette.cream.opacity(0.96),
      in: RoundedRectangle(cornerRadius: 20, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .strokeBorder(HexBrandPalette.deepPlum.opacity(0.12), lineWidth: 1)
    }
    .shadow(color: HexBrandPalette.deepPlum.opacity(0.13), radius: 9, y: 4)
  }

  private func setupRow(_ label: String, value: String, systemImage: String) -> some View {
    HStack(spacing: 10) {
      Image(systemName: systemImage)
        .foregroundStyle(HexBrandPalette.coral)
        .frame(width: 22)
        .accessibilityHidden(true)
      Text(label)
        .font(.callout.weight(.semibold))
        .foregroundStyle(HexBrandPalette.deepPlum)
      Spacer(minLength: 12)
      Text(value)
        .font(.callout)
        .foregroundStyle(HexBrandPalette.deepPlum.opacity(0.72))
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .accessibilityElement(children: .combine)
  }

  private var availabilityTint: Color {
    switch startAtLogin.status {
    case .enabled:
      HexBrandPalette.successOnCream
    case .requiresApproval:
      HexBrandPalette.coralPressed
    case .notRegistered, .notFound, .unknown, .unavailable:
      HexBrandPalette.mutedInk
    }
  }
}
