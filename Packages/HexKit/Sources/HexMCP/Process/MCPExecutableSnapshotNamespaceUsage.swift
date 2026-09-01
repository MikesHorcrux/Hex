public struct MCPExecutableSnapshotNamespaceUsage: Equatable, Sendable {
  public let namespacePath: String
  public let retainedSlotCount: Int
  public let maximumRetainedSlots: Int
  public let maximumRetainedEntries: Int
  public let maximumPathMetadataBytes: Int64
  public let maximumCopiedBytes: Int64

  init(
    namespacePath: String,
    retainedSlotCount: Int,
    policy: MCPExecutableSnapshotPolicy
  ) {
    self.namespacePath = namespacePath
    self.retainedSlotCount = retainedSlotCount
    self.maximumRetainedSlots = policy.maximumRetainedSlots
    self.maximumRetainedEntries = policy.maximumTotalRetainedEntries
    self.maximumPathMetadataBytes = policy.maximumTotalPathMetadataBytes
    self.maximumCopiedBytes = policy.maximumTotalCopiedBytes
  }
}
