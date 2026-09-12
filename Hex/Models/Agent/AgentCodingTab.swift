enum AgentCodingTab: String, CaseIterable {
  case processes
  case changes

  var title: String {
    switch self {
    case .processes: "Processes"
    case .changes: "Changes"
    }
  }
}
