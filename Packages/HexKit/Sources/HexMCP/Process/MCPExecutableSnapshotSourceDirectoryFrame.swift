import Darwin

struct MCPExecutableSnapshotSourceDirectoryFrame {
  let descriptor: Int32
  let sourceRelativePath: String
  let destinationRelativePath: String
  let initialStatus: stat
  let names: [String]
  var nextIndex: Int
  let ownsDescriptor: Bool
}
