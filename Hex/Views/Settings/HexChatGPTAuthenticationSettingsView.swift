import HexProviders
import SwiftUI

struct HexChatGPTAuthenticationSettingsView: View {
  @Bindable var model: HexInferenceBackendSettingsModel

  var body: some View {
    HStack {
      Label(model.chatGPTAccountStatus.title, systemImage: statusSymbol)
      Spacer()
      Button("Refresh") {
        model.refreshChatGPTAccountStatus()
      }
      .buttonStyle(.hexSecondaryAction)
      .disabled(model.isChatGPTLoginInProgress || model.isChatGPTLogoutInProgress)
    }

    Text(model.chatGPTAccountStatus.detail)
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

    if model.chatGPTAccountStatus != .signedIn,
      model.chatGPTLoginChallenge == nil
    {
      Button("Sign in with ChatGPT") {
        model.startChatGPTLogin()
      }
      .buttonStyle(.hexPrimaryAction)
      .disabled(model.isChatGPTLoginInProgress || model.isChatGPTLogoutInProgress)
      .accessibilityIdentifier("startChatGPTSignInButton")
    }

    if let challenge = model.chatGPTLoginChallenge {
      VStack(alignment: .leading, spacing: 8) {
        Text("Open the verification page and enter this code:")
        Text(challenge.userCode)
          .font(.headline.monospaced())
          .textSelection(.enabled)
          .accessibilityIdentifier("chatGPTDeviceCode")
        Link("Open ChatGPT verification", destination: challenge.verificationURL)

        HStack {
          Button("Finish Sign-In") {
            model.completeChatGPTLogin()
          }
          .buttonStyle(.hexPrimaryAction)
          .disabled(model.isChatGPTLoginInProgress)

          Button("Cancel", role: .cancel) {
            model.cancelChatGPTLogin()
          }
          .buttonStyle(.hexSecondaryAction)
        }
      }
      .padding(.vertical, 4)
    }

    if model.isChatGPTLoginInProgress || model.isChatGPTLogoutInProgress {
      ProgressView()
        .controlSize(.small)
    }

    if model.chatGPTAccountStatus == .signedIn {
      Button("Sign Out of ChatGPT", role: .destructive) {
        model.signOutChatGPT()
      }
      .disabled(model.isChatGPTLoginInProgress || model.isChatGPTLogoutInProgress)
    }
  }

  private var statusSymbol: String {
    switch model.chatGPTAccountStatus {
    case .signedIn:
      "checkmark.circle.fill"
    case .signedOut:
      "person.crop.circle.badge.exclamationmark"
    case .unavailable:
      "xmark.circle"
    }
  }
}
