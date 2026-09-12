import Foundation
import HexCore
import HexIPC
import HexMCP
import HexPersistence
import HexPersonality
import HexProviders

public enum HexGatewayResidentConfigurationError: Swift.Error, Equatable,
  LocalizedError, Sendable
{
  case missingVariables([String])
  case invalidVariable(String)
  case applicationSupportUnavailable
  case settingsUnavailable
  case inferenceSettingsUnavailable
  case credentialsUnavailable
  case mcpConfigurationUnavailable

  public var errorDescription: String? {
    switch self {
    case .missingVariables(let variables):
      "Resident gateway configuration is incomplete. Set \(variables.joined(separator: ", "))."
    case .invalidVariable(let variable):
      "The \(variable) resident gateway setting is invalid."
    case .applicationSupportUnavailable:
      "Hex could not locate Application Support for the resident gateway."
    case .settingsUnavailable:
      "Hex resident settings are unavailable or invalid."
    case .inferenceSettingsUnavailable:
      "Hex inference-backend settings are unavailable or invalid. Open Inference settings and choose a supported backend configuration."
    case .credentialsUnavailable:
      "Hex resident credentials are unavailable."
    case .mcpConfigurationUnavailable:
      "Hex resident MCP configuration is unavailable or invalid."
    }
  }
}
