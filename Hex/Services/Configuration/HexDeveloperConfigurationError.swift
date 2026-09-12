import Foundation

nonisolated enum HexDeveloperConfigurationError: Error, Equatable, LocalizedError, Sendable {
  case missingVariables([String])
  case invalidVariable(String)

  var errorDescription: String? {
    switch self {
    case .missingVariables(let variables):
      return
        "Live developer mode is not configured. Set \(variables.joined(separator: ", ")) before running Hex."
    case .invalidVariable(let variable):
      return "The \(variable) developer setting is invalid. Check its value and try again."
    }
  }
}
