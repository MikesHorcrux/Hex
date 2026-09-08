/// Separates configuration, installed components and Mac grants from live tool connectivity.
nonisolated enum HexCapabilitySetupStatus: Equatable, Sendable {
  case disabled
  case needsSave
  case needsInstallation
  case installing
  case installed
  case checking
  case notChecked
  case needsApproval
  case permissionsGranted

  var title: String {
    switch self {
    case .disabled: "Off"
    case .needsSave: "Save changes"
    case .needsInstallation: "Needs setup"
    case .installing: "Installing"
    case .installed: "Installed"
    case .checking: "Checking"
    case .notChecked: "Not checked"
    case .needsApproval: "Needs approval"
    case .permissionsGranted: "Permissions granted"
    }
  }

  static func browser(
    enabled: Bool, savedEnabled: Bool, installed: Bool, installing: Bool
  ) -> Self {
    if installing { return .installing }
    if enabled != savedEnabled { return .needsSave }
    if !enabled { return .disabled }
    return installed ? .installed : .needsInstallation
  }

  static func screen(
    enabled: Bool, savedEnabled: Bool, installed: Bool, checking: Bool,
    permissionsGranted: Bool?
  ) -> Self {
    if checking { return .checking }
    if enabled != savedEnabled { return .needsSave }
    if !enabled { return .disabled }
    if !installed { return .needsInstallation }
    guard let permissionsGranted else { return .notChecked }
    return permissionsGranted ? .permissionsGranted : .needsApproval
  }
}
