import Darwin

enum MCPExecutableSnapshotCreatedEntryKind: Sendable {
  case directory
  case file
  case symbolicLink
}
