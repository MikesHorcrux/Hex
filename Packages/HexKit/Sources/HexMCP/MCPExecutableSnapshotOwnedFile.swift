import Darwin

struct MCPExecutableSnapshotOwnedFile: Sendable {
  let descriptor: Int32
  var status: stat?
}
