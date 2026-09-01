enum WorkspacePathScalarPolicy {
  static func isPromptSafe(_ value: String) -> Bool {
    value.unicodeScalars.allSatisfy { scalar in
      guard !scalar.properties.isDefaultIgnorableCodePoint else {
        return false
      }
      switch scalar.properties.generalCategory {
      case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned:
        return false
      default:
        return !scalar.properties.isNoncharacterCodePoint
      }
    }
  }
}
