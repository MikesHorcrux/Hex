import Darwin

struct MCPExecutableSnapshotEntry: Sendable {
  let created: MCPExecutableSnapshotCreatedEntry
  let status: stat
}
