import SwiftUI

struct ErrorBannerView: View {
  let message: String
  let onRetry: (() -> Void)?
  let onDismiss: (() -> Void)?
  let retryTitle: String

  init(
    message: String, onRetry: (() -> Void)?, onDismiss: (() -> Void)?, retryTitle: String = "Retry"
  ) {
    self.message = message
    self.onRetry = onRetry
    self.onDismiss = onDismiss
    self.retryTitle = retryTitle
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(HexBrandPalette.accentInk)
        .padding(.top, 2)

      Text(message)
        .font(.callout)
        .foregroundStyle(HexBrandPalette.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)

      if let onRetry {
        Button(retryTitle, action: onRetry)
          .buttonStyle(.hexSecondaryAction)
          .controlSize(.small)
      }
      if let onDismiss {
        Button(action: onDismiss) {
          Image(systemName: "xmark")
            .accessibilityLabel("Dismiss error")
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 15)
    .padding(.vertical, 12)
    .frame(maxWidth: 860)
    .hexSurface(
      cornerRadius: 15,
      fill: HexBrandPalette.softCoral,
      border: HexBrandPalette.coral.opacity(0.28),
      shadowRadius: 4
    )
    .padding(.horizontal, 24)
    .padding(.top, 12)
    .accessibilityIdentifier("workspaceErrorBanner")
  }
}
