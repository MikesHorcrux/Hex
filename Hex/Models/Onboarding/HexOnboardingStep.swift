enum HexOnboardingStep: Int, CaseIterable, Sendable {
  case welcome
  case inference
  case workspace
  case tools
  case permissions
  case personality
  case ready

  var title: String {
    switch self {
    case .welcome:
      "Welcome"
    case .inference:
      "Inference"
    case .workspace:
      "Workspace"
    case .tools:
      "Tools"
    case .permissions:
      "Permissions"
    case .personality:
      "Personality"
    case .ready:
      "Ready"
    }
  }

  var position: Int { rawValue + 1 }

  var previous: Self? {
    Self(rawValue: rawValue - 1)
  }

  var next: Self? {
    Self(rawValue: rawValue + 1)
  }
}
