import Foundation

struct WorkspaceDirectoryResultSize {
  private static let emptyResultByteCount = #"{"entries":[]}"#.utf8.count

  private(set) var byteCount: Int
  private var entryCount = 0

  init(maximumBytes: Int) throws {
    guard Self.emptyResultByteCount <= maximumBytes else {
      throw WorkspaceFileSystemError.capacityExceeded
    }
    byteCount = Self.emptyResultByteCount
  }

  mutating func append(
    _ entry: WorkspaceDirectoryEntry,
    maximumBytes: Int
  ) throws {
    let encodedEntry: Data
    do {
      encodedEntry = try JSONEncoder().encode(WorkspaceToolResult.directoryEntry(entry))
    } catch {
      throw WorkspaceFileSystemError.ioFailure
    }
    let commaByteCount = entryCount == 0 ? 0 : 1
    let (entryAndCommaBytes, entryOverflowed) = encodedEntry.count.addingReportingOverflow(
      commaByteCount
    )
    let (candidateByteCount, resultOverflowed) = byteCount.addingReportingOverflow(
      entryAndCommaBytes
    )
    guard
      !entryOverflowed,
      !resultOverflowed,
      candidateByteCount <= maximumBytes
    else {
      throw WorkspaceFileSystemError.capacityExceeded
    }
    byteCount = candidateByteCount
    entryCount += 1
  }
}
