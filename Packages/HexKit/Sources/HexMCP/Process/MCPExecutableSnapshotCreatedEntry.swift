import Darwin

struct MCPExecutableSnapshotCreatedEntry: Sendable {
  let relativePath: String
  let kind: MCPExecutableSnapshotCreatedEntryKind
  let status: stat
}
