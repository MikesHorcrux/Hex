import Darwin

struct MCPExecutableSnapshotImageRecord {
  let sourceRelativePath: String
  let snapshotRelativePath: String
  let image: MCPMachOImage
  let sourceInheritedRunpaths: [MCPExecutableSnapshotExpandedRunpath]
  let snapshotInheritedRunpaths: [MCPExecutableSnapshotExpandedRunpath]
}
