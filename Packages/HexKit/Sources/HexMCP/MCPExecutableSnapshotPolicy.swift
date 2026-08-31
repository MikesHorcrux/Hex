/// Persistent namespace and per-snapshot admission limits for mutable MCP executables.
public struct MCPExecutableSnapshotPolicy: Equatable, Sendable {
  /// The default fixed-namespace policy used by `MCPServerConfiguration`.
  public static let standard = MCPExecutableSnapshotPolicy(
    validatedMaximumRetainedSlots: 32,
    maximumEntriesPerSlot: 2_048,
    maximumPathMetadataBytesPerSlot: 8 * 1_024 * 1_024,
    maximumCopiedBytesPerSlot: 128 * 1_024 * 1_024
  )

  public let maximumRetainedSlots: Int
  public let maximumEntriesPerSlot: Int
  public let maximumPathMetadataBytesPerSlot: Int64
  public let maximumCopiedBytesPerSlot: Int64

  /// The maximum retained entry count when every fixed slot is consumed.
  public var maximumTotalRetainedEntries: Int {
    maximumRetainedSlots * maximumEntriesPerSlot
  }

  /// The maximum admitted pathname and symbolic-link metadata across all fixed slots.
  public var maximumTotalPathMetadataBytes: Int64 {
    Int64(maximumRetainedSlots) * maximumPathMetadataBytesPerSlot
  }

  /// The maximum copied regular-file bytes admitted across all fixed slots.
  public var maximumTotalCopiedBytes: Int64 {
    Int64(maximumRetainedSlots) * maximumCopiedBytesPerSlot
  }

  public init(
    maximumRetainedSlots: Int,
    maximumEntriesPerSlot: Int,
    maximumPathMetadataBytesPerSlot: Int64,
    maximumCopiedBytesPerSlot: Int64
  ) throws {
    guard
      (1...4_096).contains(maximumRetainedSlots),
      (1...32_768).contains(maximumEntriesPerSlot),
      (4_096...256 * 1_024 * 1_024).contains(maximumPathMetadataBytesPerSlot),
      (1...768 * 1_024 * 1_024).contains(maximumCopiedBytesPerSlot)
    else {
      throw MCPExecutableSnapshotPolicyError.invalidLimit
    }
    self.init(
      validatedMaximumRetainedSlots: maximumRetainedSlots,
      maximumEntriesPerSlot: maximumEntriesPerSlot,
      maximumPathMetadataBytesPerSlot: maximumPathMetadataBytesPerSlot,
      maximumCopiedBytesPerSlot: maximumCopiedBytesPerSlot
    )
  }

  private init(
    validatedMaximumRetainedSlots: Int,
    maximumEntriesPerSlot: Int,
    maximumPathMetadataBytesPerSlot: Int64,
    maximumCopiedBytesPerSlot: Int64
  ) {
    self.maximumRetainedSlots = validatedMaximumRetainedSlots
    self.maximumEntriesPerSlot = maximumEntriesPerSlot
    self.maximumPathMetadataBytesPerSlot = maximumPathMetadataBytesPerSlot
    self.maximumCopiedBytesPerSlot = maximumCopiedBytesPerSlot
  }
}
