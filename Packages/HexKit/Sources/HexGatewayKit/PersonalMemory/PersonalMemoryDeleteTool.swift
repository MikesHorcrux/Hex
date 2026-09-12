import Dispatch
import Foundation
import HexCapabilities
import HexCore
import HexPersonality

struct PersonalMemoryDeleteTool: HostTool, Sendable {
  let definition = ToolDefinition(
    name: PersonalMemoryToolName.delete.rawValue,
    description:
      "Permanently forget one personal memory from the current profile scope after authorization.",
    inputSchema: HostToolSchema.object(
      properties: [
        "scope": HostToolSchema.string(
          "The current profile scope. It must exactly match the host-bound scope.",
          maximumLength: 128
        ),
        "id": HostToolSchema.string(
          "The exact stable memory identifier to forget.",
          maximumLength: 256
        ),
      ],
      required: ["scope", "id"]
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
      toolName: .delete,
      allowedNames: ["scope", "id"]
    )
    let scope = try arguments.requiredScope(boundTo: context.scope)
    let id = try arguments.requiredID()
    try await context.authorizationLedger.record(call: call, runID: executionContext.runID)
    return AuthorizationRequest(
      runID: executionContext.runID,
      toolCallID: call.id,
      capability: CapabilityID(rawValue: "personal.memory.delete"),
      operation: "delete",
      resource: PersonalMemoryToolAuthorization.resource(for: scope),
      details: [
        "scope": .string(scope.rawValue),
        "id_bytes": .integer(Int64(id.rawValue.utf8.count)),
      ],
      explanation:
        "Allow Hex to permanently forget one personal memory in the current profile scope."
    )
  }

  func execute(
    _ call: ToolCall,
    in executionContext: ToolExecutionContext
  ) async throws -> ToolResult {
    do {
      let arguments = try PersonalMemoryToolArguments(
        call,
        toolName: .delete,
        allowedNames: ["scope", "id"]
      )
      let scope = try arguments.requiredScope(boundTo: context.scope)
      let id = try arguments.requiredID()
      try await context.authorizationLedger.take(call: call, runID: executionContext.runID)
      let deleted = try await context.memoryStore.remove(id: id, scope: scope)
      return PersonalMemoryToolResponse.deleteResult(
        id: id,
        scope: scope,
        deleted: deleted,
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
