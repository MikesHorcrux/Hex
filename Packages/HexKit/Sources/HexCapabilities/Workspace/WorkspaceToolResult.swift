import HexCore

enum WorkspaceToolResult {
  static func file(
    _ file: WorkspaceTextFile,
    callID: ToolCallID,
    includesContent: Bool
  ) -> ToolResult {
    var output: [String: JSONValue] = [
      "path": .string(file.path),
      "revision": .string(file.revision),
      "byte_count": .integer(Int64(file.byteCount)),
    ]
    if includesContent {
      output["content"] = .string(file.content)
    }
    return ToolResult(toolCallID: callID, status: .success, output: .object(output))
  }

  static func directory(
    _ entries: [WorkspaceDirectoryEntry],
    callID: ToolCallID
  ) -> ToolResult {
    let values = entries.map(directoryEntry)
    return ToolResult(
      toolCallID: callID,
      status: .success,
      output: .object(["entries": .array(values)])
    )
  }

  static func directoryEntry(_ entry: WorkspaceDirectoryEntry) -> JSONValue {
    var value: [String: JSONValue] = [
      "path": .string(entry.path),
      "name": .string(entry.name),
      "kind": .string(entry.kind.rawValue),
    ]
    if let byteCount = entry.byteCount {
      value["byte_count"] = .integer(Int64(byteCount))
    }
    return .object(value)
  }

  static func search(
    _ matches: [WorkspaceSearchMatch],
    callID: ToolCallID
  ) -> ToolResult {
    let values = matches.map { match in
      JSONValue.object([
        "path": .string(match.path),
        "line": .integer(Int64(match.line)),
        "text": .string(match.text),
        "is_truncated": .boolean(match.isTruncated),
      ])
    }
    return ToolResult(
      toolCallID: callID,
      status: .success,
      output: .object(["matches": .array(values)])
    )
  }

  static func failure(
    _ error: Error,
    callID: ToolCallID
  ) throws -> ToolResult {
    if error is CancellationError {
      throw CancellationError()
    }
    let code: String
    switch error {
    case is ToolCallArgumentsError:
      code = "invalid_arguments"
    case WorkspaceFileSystemError.invalidConfiguration:
      code = "invalid_configuration"
    case WorkspaceFileSystemError.invalidRoot:
      code = "invalid_root"
    case WorkspaceFileSystemError.invalidPath:
      code = "invalid_path"
    case WorkspaceFileSystemError.invalidWorkingDirectory:
      code = "invalid_working_directory"
    case WorkspaceFileSystemError.notFound:
      code = "not_found"
    case WorkspaceFileSystemError.notDirectory:
      code = "not_directory"
    case WorkspaceFileSystemError.notRegularFile:
      code = "not_regular_file"
    case WorkspaceFileSystemError.symbolicLinkRejected:
      code = "symbolic_link_rejected"
    case WorkspaceFileSystemError.hardLinkRejected:
      code = "hard_link_rejected"
    case WorkspaceFileSystemError.fileTooLarge:
      code = "file_too_large"
    case WorkspaceFileSystemError.invalidUTF8:
      code = "invalid_utf8"
    case WorkspaceFileSystemError.capacityExceeded:
      code = "capacity_exceeded"
    case WorkspaceFileSystemError.destinationExists:
      code = "destination_exists"
    case WorkspaceFileSystemError.invalidRevision:
      code = "invalid_revision"
    case WorkspaceFileSystemError.revisionConflict:
      code = "revision_conflict"
    case WorkspaceFileSystemError.replacementCountMismatch:
      code = "replacement_count_mismatch"
    case WorkspaceFileSystemError.ioFailure:
      code = "io_failure"
    default:
      throw error
    }
    return ToolResult(
      toolCallID: callID,
      status: .failure,
      output: .object(["error": .string(code)])
    )
  }
}
