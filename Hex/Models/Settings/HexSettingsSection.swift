enum HexSettingsSection: String, CaseIterable, Identifiable {
  case general
  case inference
  case workspace
  case tools
  case permissions
  case personality
  case heartbeats

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general:
      "General"
    case .inference:
      "Inference"
    case .workspace:
      "Workspace"
    case .tools:
      "Tools & MCP"
    case .permissions:
      "Permissions"
    case .personality:
      "Personality"
    case .heartbeats:
      "Heartbeats"
    }
  }

  var systemImage: String {
    switch self {
    case .general:
      "gearshape"
    case .inference:
      "cpu"
    case .workspace:
      "folder"
    case .tools:
      "wrench.and.screwdriver"
    case .permissions:
      "hand.raised"
    case .personality:
      "person.crop.circle"
    case .heartbeats:
      "calendar.badge.clock"
    }
  }
}
