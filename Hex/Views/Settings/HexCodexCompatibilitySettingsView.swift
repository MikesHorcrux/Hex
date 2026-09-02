import HexProviders
import SwiftUI
import UniformTypeIdentifiers

struct HexCodexCompatibilitySettingsView: View {
  @Bindable var model: HexInferenceBackendSettingsModel
  @State private var isSelectingExecutable = false
  @State private var isSelectingWorkingDirectory = false

  var body: some View {
    Section {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(model.codexExecutableDisplayName)
          .lineLimit(2)
          .truncationMode(.middle)
          .foregroundStyle(model.codexExecutableURL == nil ? .secondary : .primary)
        Spacer(minLength: 10)
        Button("Choose Executable") {
          isSelectingExecutable = true
        }
        .disabled(
          model.isCodexLoginInProgress || model.isCodexLogoutInProgress
            || model.codexLoginChallenge != nil
        )
      }
      .accessibilityElement(children: .contain)

      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(model.codexWorkingDirectoryDisplayName)
          .lineLimit(2)
          .truncationMode(.middle)
          .foregroundStyle(model.codexWorkingDirectoryURL == nil ? .secondary : .primary)
        Spacer(minLength: 10)
        Button("Choose Folder") {
          isSelectingWorkingDirectory = true
        }
        .disabled(
          model.isCodexLoginInProgress || model.isCodexLogoutInProgress
            || model.codexLoginChallenge != nil
        )
      }
      .accessibilityElement(children: .contain)

      HStack {
        Label(model.codexAccountStatus.title, systemImage: statusSymbol)
        Spacer()
        Button("Refresh") {
          model.refreshCodexAccountStatus()
        }
        .disabled(
          model.codexAccountStatus == .checking || model.isCodexLoginInProgress
            || model.isCodexLogoutInProgress || model.codexLoginChallenge != nil
        )
      }
      Text(model.codexAccountStatus.detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Picker("Sign-in method", selection: $model.codexLoginMode) {
        Text("Browser").tag(CodexChatGPTLoginMode.browser)
        Text("Device code").tag(CodexChatGPTLoginMode.deviceCode)
      }
      .disabled(
        model.isCodexLoginInProgress || model.isCodexLogoutInProgress
          || model.codexLoginChallenge != nil
      )

      Button("Start Codex sign-in") {
        model.startCodexLogin()
      }
      .disabled(
        model.codexExecutableURL == nil || model.isCodexLoginInProgress
          || model.isCodexLogoutInProgress || model.codexLoginChallenge != nil
      )

      if model.isCodexLoginInProgress || model.isCodexLogoutInProgress {
        ProgressView()
          .controlSize(.small)
      }

      if let challenge = model.codexLoginChallenge {
        VStack(alignment: .leading, spacing: 8) {
          switch challenge {
          case .browser(_, let authorizationURL):
            Text("Open the Codex authorization page in your browser.")
            Link("Open authorization page", destination: authorizationURL)
          case .deviceCode(_, let userCode, let verificationURL):
            Text("Open the Codex verification page and enter this code:")
            Text(userCode)
              .font(.headline.monospaced())
              .textSelection(.enabled)
            Link("Open verification page", destination: verificationURL)
          }

          HStack {
            Button("Check for completion") {
              model.completeCodexLogin()
            }
            .disabled(model.isCodexLoginInProgress)

            Button("Cancel sign-in", role: .cancel) {
              model.cancelCodexLogin()
            }
            .disabled(model.isCodexLogoutInProgress)
          }
        }
        .padding(.vertical, 4)
      }

      if case .signedIn = model.codexAccountStatus {
        Button("Sign out of Codex account", role: .destructive) {
          model.logoutCodexAccount()
        }
        .disabled(
          model.isCodexLoginInProgress || model.isCodexLogoutInProgress
            || model.codexLoginChallenge != nil
        )
      }
    } header: {
      Text("Codex compatibility / app-server")
    } footer: {
      Text(
        "A ChatGPT subscription is not an OpenAI API key. Sign-in uses only the browser or device-code flows exposed by Codex app-server. This mode is a compatibility account/runtime integration, not raw Responses API inference."
      )
    }
    .fileImporter(
      isPresented: $isSelectingExecutable,
      allowedContentTypes: [.item],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        if let url = urls.first {
          model.chooseCodexExecutable(url)
        }
      case .failure:
        model.errorMessageForFileSelectionFailure()
      }
    }
    .fileImporter(
      isPresented: $isSelectingWorkingDirectory,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        if let url = urls.first {
          model.chooseCodexWorkingDirectory(url)
        }
      case .failure:
        model.errorMessageForFileSelectionFailure()
      }
    }
  }

  private var statusSymbol: String {
    switch model.codexAccountStatus {
    case .signedIn(account: _):
      "checkmark.circle.fill"
    case .signedOut, .requiresOpenAIAuthentication:
      "exclamationmark.circle"
    case .checking:
      "arrow.triangle.2.circlepath"
    case .notConfigured:
      "questionmark.circle"
    case .unavailable:
      "xmark.circle"
    }
  }
}
