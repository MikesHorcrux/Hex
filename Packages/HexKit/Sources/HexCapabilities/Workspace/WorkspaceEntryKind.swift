public enum WorkspaceEntryKind: String, Codable, CaseIterable, Sendable {
  case file
  case directory
  case symbolicLink
  case other
}
