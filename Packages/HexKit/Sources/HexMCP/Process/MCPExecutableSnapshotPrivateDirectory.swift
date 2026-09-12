import Darwin

struct MCPExecutableSnapshotPrivateDirectory {
  let namespaceParentDescriptor: Int32
  let namespaceBasename: String
  let namespaceStatus: stat
  let parentDescriptor: Int32
  let basename: String
  let path: String
  let descriptor: Int32
  let initialStatus: stat
}
