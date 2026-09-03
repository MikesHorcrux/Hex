import Foundation

enum HexManagedToolInstallerError: Error, LocalizedError, Sendable {
  case invalidDownload
  case invalidArchive
  case invalidInstallation
  case commandFailed
  case unsupportedArchitecture

  var errorDescription: String? {
    switch self {
    case .invalidDownload:
      "Hex could not verify the downloaded capability."
    case .invalidArchive:
      "Hex rejected an unsafe capability archive."
    case .invalidInstallation:
      "The capability did not pass validation after installation."
    case .commandFailed:
      "A capability setup command did not complete successfully."
    case .unsupportedArchitecture:
      "This Mac architecture is not supported by the current capability bundle."
    }
  }
}
