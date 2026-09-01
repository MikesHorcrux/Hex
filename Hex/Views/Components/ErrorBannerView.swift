import SwiftUI

struct ErrorBannerView: View {
  let message: String
  let onRetry: () -> Void
  let onDismiss: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .padding(.top, 2)

      Text(message)
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)

      Button("Retry", action: onRetry)
        .buttonStyle(.hexSecondaryAction)
        .controlSize(.small)
      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .accessibilityLabel("Dismiss error")
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
    .padding(.horizontal, 20)
    .padding(.top, 12)
  }
}
