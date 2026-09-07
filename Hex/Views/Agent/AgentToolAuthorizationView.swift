import HexCore
import SwiftUI

struct AgentToolAuthorizationView: View {
  let request: AuthorizationRequest
  let isSubmitting: Bool
  let onChoice: (AuthorizationDecisionChoice) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 9) {
        Image(systemName: "lock.shield.fill")
          .font(.title3)
          .foregroundStyle(HexBrandPalette.accentInk)
        VStack(alignment: .leading, spacing: 2) {
          Text("Hex needs your approval")
            .font(.headline)
            .foregroundStyle(HexBrandPalette.ink)
            .accessibilityIdentifier("toolAuthorizationRequest")
          Text("This exact operation is paused until you choose.")
            .font(.caption)
            .foregroundStyle(HexBrandPalette.mutedInk)
        }
        Spacer()
        if isSubmitting {
          ProgressView()
            .controlSize(.small)
            .tint(HexBrandPalette.coral)
        }
      }

      Text(request.explanation)
        .font(.callout)
        .foregroundStyle(HexBrandPalette.ink)
        .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: 6) {
        detailRow("Capability", request.capability.rawValue)
        detailRow("Operation", request.operation)
        if let resource = request.resource {
          detailRow("Resource", resource)
        }
        ForEach(request.details.keys.sorted(), id: \.self) { key in
          if let value = request.details[key] {
            detailRow(key, HexJSONValueFormatter.string(from: value))
          }
        }
      }
      .padding(10)
      .background(HexBrandPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .strokeBorder(HexBrandPalette.hairline, lineWidth: 1)
      }

      HStack {
        Button(AuthorizationDecisionChoice.deny.buttonTitle, role: .destructive) {
          onChoice(.deny)
        }
        .accessibilityIdentifier("denyAuthorization")

        Spacer()

        Button(AuthorizationDecisionChoice.allowOnce.buttonTitle) {
          onChoice(.allowOnce)
        }
        .buttonStyle(.hexSecondaryAction)
        .accessibilityIdentifier("allowAuthorizationOnce")

        Button(AuthorizationDecisionChoice.allowForSession.buttonTitle) {
          onChoice(.allowForSession)
        }
        .buttonStyle(.hexPrimaryAction)
        .accessibilityIdentifier("allowAuthorizationForSession")
      }
      .disabled(isSubmitting)
      Text(
        "Allow once covers only this action. Allow for session remembers this exact operation and target across conversations and scheduled work until Hex Agent restarts; revoke it in the Approval inbox."
      )
      .font(.caption).foregroundStyle(HexBrandPalette.mutedInk)
    }
    .padding(16)
    .hexSurface(
      cornerRadius: 18,
      fill: HexBrandPalette.softApricot,
      border: HexBrandPalette.apricot.opacity(0.36),
      shadowRadius: 7
    )
  }

  @ViewBuilder
  private func detailRow(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(label)
        .font(.caption.weight(.semibold))
        .foregroundStyle(HexBrandPalette.mutedInk)
        .frame(width: 90, alignment: .leading)
      Text(value)
        .font(.caption.monospaced())
        .foregroundStyle(HexBrandPalette.ink)
        .textSelection(.enabled)
    }
  }
}
