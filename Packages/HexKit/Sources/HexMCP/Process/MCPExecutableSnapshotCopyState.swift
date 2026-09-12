import Darwin

struct MCPExecutableSnapshotCopyState {
  let policy: MCPExecutableSnapshotPolicy
  var allowsTrustedHardLinks: Bool
  var createdEntries: [MCPExecutableSnapshotCreatedEntry] = []
  var createdDirectoryStatuses: [String: stat] = [:]
  var copiedFiles: Set<String> = []
  var copiedFileSources: [String: String] = [:]
  var copiedPackages: [String: String] = [:]
  var ownedRegularFiles: [MCPExecutableSnapshotOwnedFile] = []
  var copiedByteCount = off_t(0)
  var pathMetadataByteCount = Int64(0)
  var admittedEntryCount = 0
  var admittedRunpathCount = 0
  var admittedRunpathByteCount = Int64(0)

  init(
    policy: MCPExecutableSnapshotPolicy,
    allowsTrustedHardLinks: Bool = false
  ) {
    self.policy = policy
    self.allowsTrustedHardLinks = allowsTrustedHardLinks
  }

  mutating func admitEntry(
    relativePath: String,
    additionalPathMetadataBytes: Int64 = 0,
    copiedBytes: off_t
  ) throws {
    guard
      additionalPathMetadataBytes >= 0,
      copiedBytes >= 0,
      admittedEntryCount < policy.maximumEntriesPerSlot
    else {
      throw MCPClientSessionError.limitExceeded
    }
    let (pathBytes, entryPathOverflowed) = Int64(relativePath.utf8.count + 1)
      .addingReportingOverflow(additionalPathMetadataBytes)
    let (nextPathBytes, totalPathOverflowed) =
      pathMetadataByteCount.addingReportingOverflow(pathBytes)
    let (nextCopiedBytes, copiedOverflowed) =
      copiedByteCount.addingReportingOverflow(copiedBytes)
    guard
      !entryPathOverflowed,
      !totalPathOverflowed,
      !copiedOverflowed,
      nextPathBytes <= policy.maximumPathMetadataBytesPerSlot,
      nextCopiedBytes <= off_t(policy.maximumCopiedBytesPerSlot)
    else {
      throw MCPClientSessionError.limitExceeded
    }
    admittedEntryCount += 1
    pathMetadataByteCount = nextPathBytes
    copiedByteCount = nextCopiedBytes
  }

  mutating func admitRunpathBudget(
    source: [MCPExecutableSnapshotExpandedRunpath],
    snapshot: [MCPExecutableSnapshotExpandedRunpath]
  ) throws {
    guard
      source.count <= MCPExecutableSnapshot.maximumRunpathsPerImage,
      snapshot.count <= MCPExecutableSnapshot.maximumRunpathsPerImage
    else {
      throw MCPClientSessionError.limitExceeded
    }

    func byteCount(of runpaths: [MCPExecutableSnapshotExpandedRunpath]) -> Int64? {
      var total = Int64(0)
      for runpath in runpaths {
        let (next, overflowed) = total.addingReportingOverflow(
          Int64(runpath.relativePath.utf8.count)
        )
        guard !overflowed else { return nil }
        total = next
      }
      return total
    }

    guard
      let sourceBytes = byteCount(of: source),
      let snapshotBytes = byteCount(of: snapshot),
      sourceBytes <= Int64(MCPExecutableSnapshot.maximumRunpathBytesPerImage),
      snapshotBytes <= Int64(MCPExecutableSnapshot.maximumRunpathBytesPerImage)
    else {
      throw MCPClientSessionError.limitExceeded
    }
    let imageCount = source.count + snapshot.count
    let (nextCount, countOverflowed) = admittedRunpathCount.addingReportingOverflow(imageCount)
    let imageBytes = sourceBytes + snapshotBytes
    let (nextBytes, bytesOverflowed) =
      admittedRunpathByteCount
      .addingReportingOverflow(imageBytes)
    guard
      !countOverflowed,
      !bytesOverflowed,
      nextCount <= MCPExecutableSnapshot.maximumClosureRunpaths,
      nextBytes <= Int64(MCPExecutableSnapshot.maximumClosureRunpathBytes)
    else {
      throw MCPClientSessionError.limitExceeded
    }
    admittedRunpathCount = nextCount
    admittedRunpathByteCount = nextBytes
  }
}
