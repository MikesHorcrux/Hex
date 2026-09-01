public enum MCPExecutableSnapshotAdmissionError: Error, Equatable, Sendable {
  case namespaceExhausted(MCPExecutableSnapshotNamespaceUsage)
}
