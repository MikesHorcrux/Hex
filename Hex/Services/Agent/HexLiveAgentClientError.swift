import Foundation
import HexCapabilities
import HexCore
import HexGatewayKit
import HexIPC
import HexPersistence
import HexProviders

enum HexLiveAgentClientError: Error, Equatable, LocalizedError, Sendable {
  case applicationSupportUnavailable
  case workspaceUnavailable
  case modelMismatch(expected: String)

  var errorDescription: String? {
    switch self {
    case .applicationSupportUnavailable:
      "Hex could not locate Application Support for its local event journal."
    case .workspaceUnavailable:
      "The in-process developer gateway needs an absolute workspace folder. Set HEX_WORKSPACE_ROOT and try again."
    case .modelMismatch(let expected):
      "The selected model must match HEX_OPENAI_MODEL (\(expected))."
    }
  }
}
