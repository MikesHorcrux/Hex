enum AgentChangesSection: String, CaseIterable {
  case unstaged
  case staged
  case baseline
  case patches

  var title: String {
    switch self {
    case .unstaged: "Unstaged now"
    case .staged: "Staged now"
    case .baseline: "Starting changes"
    case .patches: "Hex patches"
    }
  }
}
