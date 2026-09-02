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
      }
      .accessibilityElement(children: .contain)

      HStack {
        Label(model.codexAccountStatus.title, systemImage: statusSymbol)
        Spacer()
        Button("Refresh") {
          model.refreshCodexAccountStatus()
        }
        .disabled(model.codexAccountStatus == .checking)
      }
      Text(model.codexAccountStatus.detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    } header: {
      Text("Codex compatibility / app-server")
    } footer: {
      Text(
        "A ChatGPT subscription is not an OpenAI API key. This mode uses the Codex app-server account/runtime and is not raw Responses API inference."
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
