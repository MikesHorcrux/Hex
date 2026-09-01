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
          .foregroundStyle(.orange)
        VStack(alignment: .leading, spacing: 2) {
          Text("Hex needs your approval")
            .font(.headline)
          Text("This exact operation is paused until you choose.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if isSubmitting {
          ProgressView()
            .controlSize(.small)
        }
      }

      Text(request.explanation)
        .font(.callout)
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
      .background(
        Color(nsColor: .textBackgroundColor).opacity(0.66), in: RoundedRectangle(cornerRadius: 8))

      HStack {
        Button(AuthorizationDecisionChoice.deny.buttonTitle, role: .destructive) {
          onChoice(.deny)
        }
        .keyboardShortcut(.escape)

        Spacer()

        Button(AuthorizationDecisionChoice.allowOnce.buttonTitle) {
          onChoice(.allowOnce)
        }
        .buttonStyle(.hexSecondaryAction)

        Button(AuthorizationDecisionChoice.allowForSession.buttonTitle) {
          onChoice(.allowForSession)
        }
        .buttonStyle(.hexPrimaryAction)
        .keyboardShortcut(.defaultAction)
      }
      .disabled(isSubmitting)
    }
    .padding(14)
    .background(.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(.orange.opacity(0.32))
    }
    .accessibilityIdentifier("toolAuthorizationRequest")
  }

  @ViewBuilder
  private func detailRow(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(label)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 90, alignment: .leading)
      Text(value)
        .font(.caption.monospaced())
        .textSelection(.enabled)
    }
  }
}
