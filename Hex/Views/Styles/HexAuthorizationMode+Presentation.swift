import HexCore

extension HexAuthorizationMode {
  var permissionTitle: String {
    switch self {
    case .askEveryTime: "Ask for approval"
    case .approveForMe: "Approve for me"
    case .fullAccess: "Full access"
    }
  }

  var permissionSummary: String {
    switch self {
    case .askEveryTime: "Ask when an action needs new access."
    case .approveForMe: "Approve low-risk reads. Ask for other new access."
    case .fullAccess: "Run tools and commands without Hex approval prompts."
    }
  }

  var permissionSymbol: String {
    switch self {
    case .askEveryTime: "hand.raised"
    case .approveForMe: "checkmark.shield"
    case .fullAccess: "exclamationmark.shield"
    }
  }
}
