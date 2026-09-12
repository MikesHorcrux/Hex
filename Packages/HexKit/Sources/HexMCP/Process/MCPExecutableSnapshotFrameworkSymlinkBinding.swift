import Darwin

struct MCPExecutableSnapshotFrameworkSymlinkBinding {
  let parentDescriptor: Int32
  let name: String
  let status: stat
  let target: String
}
