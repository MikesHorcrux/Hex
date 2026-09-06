import Foundation

enum HexResidentReloadError: Error, LocalizedError, Sendable {
  case unavailable(String)

  var errorDescription: String? {
    switch self {
    case .unavailable(let message): message
    }
  }
}
