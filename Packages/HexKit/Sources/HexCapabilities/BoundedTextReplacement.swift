struct BoundedTextReplacement {
  static func build(
    source: String,
    replacing oldText: String,
    with newText: String,
    expectedOccurrences: Int,
    maximumBytes: Int
  ) throws -> String {
    let oldByteCount = oldText.utf8.count
    let newByteCount = newText.utf8.count
    var occurrenceCount = 0
    var searchStart = source.startIndex

    while searchStart < source.endIndex,
      let range = source.range(
        of: oldText,
        range: searchStart..<source.endIndex
      )
    {
      try Task.checkCancellation()
      occurrenceCount += 1
      guard occurrenceCount <= 10_000 else {
        throw WorkspaceFileSystemError.replacementCountMismatch
      }
      searchStart = range.upperBound
    }
    guard occurrenceCount == expectedOccurrences else {
      throw WorkspaceFileSystemError.replacementCountMismatch
    }

    let (removedByteCount, removalOverflowed) = oldByteCount.multipliedReportingOverflow(
      by: occurrenceCount
    )
    let (insertedByteCount, insertionOverflowed) = newByteCount.multipliedReportingOverflow(
      by: occurrenceCount
    )
    guard
      !removalOverflowed,
      !insertionOverflowed,
      removedByteCount <= source.utf8.count
    else {
      throw WorkspaceFileSystemError.fileTooLarge
    }
    let retainedByteCount = source.utf8.count - removedByteCount
    let (resultByteCount, resultOverflowed) = retainedByteCount.addingReportingOverflow(
      insertedByteCount
    )
    guard !resultOverflowed, resultByteCount <= maximumBytes else {
      throw WorkspaceFileSystemError.fileTooLarge
    }

    var result = ""
    result.reserveCapacity(resultByteCount)
    var copiedThrough = source.startIndex
    searchStart = source.startIndex
    var constructedByteCount = 0
    while searchStart < source.endIndex,
      let range = source.range(
        of: oldText,
        range: searchStart..<source.endIndex
      )
    {
      try Task.checkCancellation()
      let retained = source[copiedThrough..<range.lowerBound]
      let (afterRetained, retainedOverflowed) = constructedByteCount.addingReportingOverflow(
        retained.utf8.count
      )
      let (afterReplacement, replacementOverflowed) = afterRetained.addingReportingOverflow(
        newByteCount
      )
      guard
        !retainedOverflowed,
        !replacementOverflowed,
        afterReplacement <= maximumBytes
      else {
        throw WorkspaceFileSystemError.fileTooLarge
      }
      result.append(contentsOf: retained)
      result.append(newText)
      constructedByteCount = afterReplacement
      copiedThrough = range.upperBound
      searchStart = range.upperBound
    }

    let remainder = source[copiedThrough..<source.endIndex]
    let (finalByteCount, finalOverflowed) = constructedByteCount.addingReportingOverflow(
      remainder.utf8.count
    )
    guard
      !finalOverflowed,
      finalByteCount == resultByteCount,
      finalByteCount <= maximumBytes
    else {
      throw WorkspaceFileSystemError.fileTooLarge
    }
    result.append(contentsOf: remainder)
    return result
  }
}
