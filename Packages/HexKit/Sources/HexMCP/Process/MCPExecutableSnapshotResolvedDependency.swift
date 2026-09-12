import Darwin

struct MCPExecutableSnapshotResolvedDependency {
  let sourceRelativePath: String
  let snapshotRelativePath: String
  let descriptor: Int32
  let status: stat
}
