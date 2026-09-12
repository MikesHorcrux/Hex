import Darwin

struct MCPExecutableSnapshotExpandedRunpath: Hashable {
  let relativePath: String
  let isTrustedSystemPath: Bool
  let isExternalPath: Bool
}
