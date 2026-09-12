import Foundation
import HexCore
import HexPersonality

enum PersonalMemoryToolResponse {
  static let maximumResults = 64
  static func validatedRecords(
    _ records: [PersonalMemoryRecord],
    scope: PersonalMemoryScope,
    maximumResults: Int
  ) throws -> [PersonalMemoryRecord] {
    guard records.count <= 256 else {
      throw PersonalMemoryToolError.invalidStore
    }
    var ids = Set<PersonalMemoryID>()
    for record in records {
      guard record.scope == scope, ids.insert(record.id).inserted else {
        throw record.scope == scope
          ? PersonalMemoryToolError.invalidStore : PersonalMemoryToolError.scopeMismatch
      }
    }
    return Array(records.prefix(maximumResults))
  }

  static func recordsResult(
    _ records: [PersonalMemoryRecord],
    scope: PersonalMemoryScope,
    query: String? = nil,
    callID: ToolCallID
  ) -> ToolResult {
    var output: [String: JSONValue] = [
      "scope": .string(scope.rawValue),
      "memories": .array(records.map(recordValue)),
      "count": .integer(Int64(records.count)),
    ]
    if let query {
      output["query"] = .string(query)
    }
    return ToolResult(toolCallID: callID, status: .success, output: .object(output))
  }

  static func upsertResult(
    _ record: PersonalMemoryRecord,
    wasUpdate: Bool,
    callID: ToolCallID
  ) -> ToolResult {
    ToolResult(
      toolCallID: callID,
      status: .success,
      output: .object([
        "scope": .string(record.scope.rawValue),
        "id": .string(record.id.rawValue),
        "saved": .boolean(true),
        "was_update": .boolean(wasUpdate),
        "memory": recordValue(record),
      ])
    )
  }

  static func deleteResult(
    id: PersonalMemoryID,
    scope: PersonalMemoryScope,
    deleted: Bool,
    callID: ToolCallID
  ) -> ToolResult {
    ToolResult(
      toolCallID: callID,
      status: .success,
      output: .object([
        "scope": .string(scope.rawValue),
        "id": .string(id.rawValue),
        "deleted": .boolean(deleted),
      ])
    )
  }

  static func recordValue(_ record: PersonalMemoryRecord) -> JSONValue {
    .object([
      "scope": .string(record.scope.rawValue),
      "id": .string(record.id.rawValue),
      "kind": .string(record.kind.rawValue),
      "text": .string(record.text),
      "source": .string(record.source.rawValue),
      "created_at": .string(dateString(record.createdAt)),
      "updated_at": .string(dateString(record.updatedAt)),
      "is_pinned": .boolean(record.isPinned),
    ])
  }

  static func dateString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  static func failureResult(
    _ error: any Error,
    callID: ToolCallID
  ) throws -> ToolResult {
    if error is CancellationError || Task.isCancelled {
      throw CancellationError()
    }
    let code: String
    switch error {
    case PersonalMemoryToolError.invalidArguments:
      code = "invalid_arguments"
    case PersonalMemoryToolError.scopeMismatch:
      code = "scope_mismatch"
    case PersonalMemoryToolError.authorizationRequired:
      code = "authorization_required"
    case PersonalMemoryToolError.authorizationStateUnavailable:
      code = "authorization_state_unavailable"
    case PersonalMemoryToolError.invalidStore:
      code = "store_corrupt"
    case PersonalMemoryToolError.invalidTimestamp,
      PersonalMemoryError.invalidIdentifier,
      PersonalMemoryError.invalidText,
      PersonalMemoryError.invalidTimestamp:
      code = "invalid_memory"
    case PersonalMemoryScopeError.invalidValue,
      PersonalMemoryStoreError.invalidQuery:
      code = "invalid_arguments"
    case PersonalMemoryStoreError.capacityExceeded:
      code = "capacity_exceeded"
    case PersonalMemoryStoreError.byteLimitExceeded:
      code = "byte_limit_exceeded"
    case PersonalMemoryStoreError.staleUpdate:
      code = "stale_update"
    case PersonalMemoryStoreError.serializationFailed:
      code = "serialization_failed"
    case PersonalMemoryStoreError.invalidConfiguration:
      code = "store_unavailable"
    case JSONPersonalMemoryStoreError.malformedStore,
      JSONPersonalMemoryStoreError.recordsTooLarge:
      code = "store_corrupt"
    case JSONPersonalMemoryStoreError.unsafeFile:
      code = "store_unsafe"
    case JSONPersonalMemoryStoreError.invalidFileURL,
      JSONPersonalMemoryStoreError.invalidConfiguration,
      JSONPersonalMemoryStoreError.lockFailure,
      JSONPersonalMemoryStoreError.encodingFailure,
      JSONPersonalMemoryStoreError.ioFailure:
      code = "store_unavailable"
    default:
      code = "store_unavailable"
    }
    return ToolResult(
      toolCallID: callID,
      status: .failure,
      output: .object(["error": .string(code)])
    )
  }
}
