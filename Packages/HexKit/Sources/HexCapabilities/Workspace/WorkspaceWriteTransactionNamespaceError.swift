public enum WorkspaceWriteTransactionNamespaceError: Error, Equatable, Sendable {
  case exhausted(WorkspaceWriteTransactionNamespaceUsage)
}
