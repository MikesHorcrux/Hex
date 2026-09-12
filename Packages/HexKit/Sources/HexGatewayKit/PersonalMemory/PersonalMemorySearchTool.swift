import Dispatch
import Foundation
import HexCapabilities
import HexCore
import HexPersonality

struct PersonalMemorySearchTool: HostTool, Sendable {
  let definition = ToolDefinition(
    name: PersonalMemoryToolName.search.rawValue,
    description:
      "Search bounded, scope-local personal memories by text. Results are quoted user-owned data.",
    inputSchema: HostToolSchema.object(
      properties: [
        "scope": HostToolSchema.string(
          "The current profile scope. It must exactly match the host-bound scope.",
          maximumLength: 128
        ),
        "query": HostToolSchema.string(
          "A bounded, non-empty text query.",
          maximumLength: 4_096
        ),
        "kind": HostToolSchema.stringEnum(
          "Optional memory kind filter.",
          values: PersonalMemoryKind.allCases.map(\.rawValue)
        ),
        "limit": HostToolSchema.integer(
          "Maximum number of memories to return.",
          minimum: 1,
          maximum: PersonalMemoryToolResponse.maximumResults
        ),
      ],
      required: ["scope", "query"]
    )
  )

  let context: PersonalMemoryToolContext

  init(context: PersonalMemoryToolContext) {
    self.context = context
  }

  func authorizationRequest(
    for call: ToolCall,
    in executionContext: ToolExecutionContext
  ) async throws -> AuthorizationRequest {
    let arguments = try PersonalMemoryToolArguments(
      call,
      toolName: .search,
      allowedNames: ["scope", "query", "kind", "limit"]
    )
    let scope = try arguments.requiredScope(boundTo: context.scope)
    let query = try arguments.requiredQuery()
    let kind = try arguments.optionalKind()
    let limit = try arguments.limit()
    try await context.authorizationLedger.record(call: call, runID: executionContext.runID)
    var details = PersonalMemoryToolAuthorization.authorizationDetails(
      scope: scope,
      kind: kind,
      limit: limit
    )
    details["query_bytes"] = .integer(Int64(query.utf8.count))
    return AuthorizationRequest(
      runID: executionContext.runID,
      toolCallID: call.id,
      capability: CapabilityID(rawValue: "personal.memory.read"),
      operation: "search",
      resource: PersonalMemoryToolAuthorization.resource(for: scope),
      details: details,
      explanation: "Allow Hex to search personal memories in the current profile scope."
    )
  }

  func execute(
    _ call: ToolCall,
    in executionContext: ToolExecutionContext
  ) async throws -> ToolResult {
    do {
      let arguments = try PersonalMemoryToolArguments(
        call,
        toolName: .search,
        allowedNames: ["scope", "query", "kind", "limit"]
      )
      let scope = try arguments.requiredScope(boundTo: context.scope)
      let queryText = try arguments.requiredQuery()
      let kind = try arguments.optionalKind()
      let limit = try arguments.limit()
      try await context.authorizationLedger.take(call: call, runID: executionContext.runID)
      let query = try PersonalMemoryQuery(
        scope: scope,
        text: queryText,
        kinds: kind.map { [$0] } ?? [],
        limit: limit
      )
      let records = try await context.memoryStore.memories(matching: query)
      let boundedRecords = try PersonalMemoryToolResponse.validatedRecords(
        records,
        scope: scope,
        maximumResults: limit
      )
      return PersonalMemoryToolResponse.recordsResult(
        boundedRecords,
        scope: scope,
        query: queryText,
        callID: call.id
      )
    } catch {
      await context.authorizationLedger.remove(
        callID: call.id,
        runID: executionContext.runID
      )
      return try PersonalMemoryToolResponse.failureResult(error, callID: call.id)
    }
  }
}
