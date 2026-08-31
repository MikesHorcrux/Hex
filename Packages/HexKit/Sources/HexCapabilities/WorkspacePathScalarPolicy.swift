enum WorkspacePathScalarPolicy {
  static func isPromptSafe(_ value: String) -> Bool {
    value.unicodeScalars.allSatisfy { scalar in
      switch scalar.value {
      case 0x0000...0x001F,
        0x007F...0x009F,
        0x061C,
        0x200E...0x200F,
        0x2028...0x202E,
        0x2066...0x2069:
        return false
      default:
        return true
      }
    }
  }
}
