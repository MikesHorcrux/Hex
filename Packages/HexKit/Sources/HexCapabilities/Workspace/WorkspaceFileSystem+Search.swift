import Darwin
import Foundation

extension WorkspaceFileSystem {
  public func searchText(
    _ query: String,
    under path: String,
    relativeTo workingDirectory: URL?
  ) throws -> [WorkspaceSearchMatch] {
    try searchTextReport(query, under: path, relativeTo: workingDirectory).matches
  }

  public func searchTextReport(
    _ query: String,
    under path: String,
    relativeTo workingDirectory: URL?
  ) throws -> WorkspaceSearchReport {
    guard
      !query.isEmpty,
      query.utf8.count <= 4_096,
      !query.contains("\0"),
      !query.contains("\n"),
      !query.contains("\r")
    else {
      throw WorkspaceFileSystemError.invalidPath
    }
    let rootComponents = try combinedComponents(path: path, workingDirectory: workingDirectory)
    let descriptor = try openDirectory(components: rootComponents)
    Darwin.close(descriptor)

    var fileCount = 0
    var entryCount = 0
    var totalBytes = 0
    var skippedOversizedFiles = 0
    var matches: [WorkspaceSearchMatch] = []
    try searchDirectory(
      under: rootComponents,
      depth: 0,
      query: query,
      fileCount: &fileCount,
      entryCount: &entryCount,
      totalBytes: &totalBytes,
      skippedOversizedFiles: &skippedOversizedFiles,
      matches: &matches
    )
    return WorkspaceSearchReport(matches: matches, skippedOversizedFiles: skippedOversizedFiles)
  }

  private func searchDirectory(
    under components: [String],
    depth: Int,
    query: String,
    fileCount: inout Int,
    entryCount: inout Int,
    totalBytes: inout Int,
    skippedOversizedFiles: inout Int,
    matches: inout [WorkspaceSearchMatch]
  ) throws {
    let remainingEntryCapacity = configuration.maximumSearchEntries - entryCount
    let entries = try directoryEntries(
      components: components,
      maximumEntries: remainingEntryCapacity
    )
    let (candidateEntryCount, entryCountOverflowed) = entryCount.addingReportingOverflow(
      entries.count
    )
    guard
      !entryCountOverflowed,
      candidateEntryCount <= configuration.maximumSearchEntries
    else {
      throw WorkspaceFileSystemError.capacityExceeded
    }
    entryCount = candidateEntryCount
    for entry in entries {
      try Task.checkCancellation()
      switch entry.kind {
      case .file:
        guard fileCount < configuration.maximumSearchFiles else {
          throw WorkspaceFileSystemError.capacityExceeded
        }
        fileCount += 1
        // Large assets are outside this text search's per-file scope, not a reason to discard
        // matches from code files. They still consume the bounded traversal/file budget.
        if let byteCount = entry.byteCount, byteCount > configuration.maximumReadBytes {
          skippedOversizedFiles += 1
          continue
        }
        let fileComponents = components + [entry.name]
        let (remainingSearchBytes, remainingBytesOverflowed) =
          configuration.maximumSearchBytes.subtractingReportingOverflow(totalBytes)
        guard !remainingBytesOverflowed, remainingSearchBytes >= 0 else {
          throw WorkspaceFileSystemError.capacityExceeded
        }
        let effectiveReadLimit = min(
          configuration.maximumReadBytes,
          remainingSearchBytes
        )
        let data: Data
        do {
          data = try readData(
            components: fileComponents,
            maximumBytes: effectiveReadLimit
          )
        } catch WorkspaceFileSystemError.fileTooLarge {
          if effectiveReadLimit == configuration.maximumReadBytes {
            skippedOversizedFiles += 1
            continue
          }
          // Exhausting the total search byte budget is distinct from skipping an oversized file.
          throw WorkspaceFileSystemError.capacityExceeded
        }
        let (candidateBytes, overflowed) = totalBytes.addingReportingOverflow(data.count)
        guard !overflowed, candidateBytes <= configuration.maximumSearchBytes else {
          throw WorkspaceFileSystemError.capacityExceeded
        }
        totalBytes = candidateBytes
        guard let content = String(data: data, encoding: .utf8) else {
          continue
        }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        for (offset, rawLine) in lines.enumerated() where rawLine.contains(query) {
          guard matches.count < configuration.maximumSearchMatches else {
            throw WorkspaceFileSystemError.capacityExceeded
          }
          let fullLine = String(rawLine)
          let excerpt = boundedUTF8Prefix(fullLine, maximumBytes: 1_024)
          matches.append(
            WorkspaceSearchMatch(
              path: displayPath(fileComponents),
              line: offset + 1,
              text: excerpt,
              isTruncated: excerpt != fullLine
            )
          )
        }
      case .directory:
        guard !configuration.excludedSearchDirectoryNames.contains(entry.name) else {
          continue
        }
        guard depth < configuration.maximumSearchDepth else {
          throw WorkspaceFileSystemError.capacityExceeded
        }
        try searchDirectory(
          under: components + [entry.name],
          depth: depth + 1,
          query: query,
          fileCount: &fileCount,
          entryCount: &entryCount,
          totalBytes: &totalBytes,
          skippedOversizedFiles: &skippedOversizedFiles,
          matches: &matches
        )
      case .symbolicLink, .other:
        continue
      }
    }
  }

  private func boundedUTF8Prefix(_ value: String, maximumBytes: Int) -> String {
    var result = ""
    var byteCount = 0
    for character in value {
      let fragment = String(character)
      let (candidateBytes, overflowed) = byteCount.addingReportingOverflow(
        fragment.utf8.count
      )
      guard !overflowed, candidateBytes <= maximumBytes else {
        break
      }
      result.append(character)
      byteCount = candidateBytes
    }
    return result
  }
}
