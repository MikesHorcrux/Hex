import Dispatch
import Foundation
import HexCapabilities
import HexCore
import HexPersonality

/// Exposes explicit, scope-bound personal-memory operations to the agent runtime.
///
/// The executor never derives memories from conversation text. A caller must make an explicit
/// upsert call and select one of the user-visible `PersonalMemorySource` values. Memory text is
/// returned only as tool data and is never copied into an authorization explanation or policy
/// message.
public struct PersonalMemoryToolExecutor: ToolExecutor, Sendable {
  private let executor: HostToolExecutor
  private let boundScope: PersonalMemoryScope

  public init(
    memoryStore: any PersonalMemoryStore,
    scope: PersonalMemoryScope
  ) throws {
    boundScope = scope
    let context = PersonalMemoryToolContext(
      memoryStore: memoryStore,
      scope: scope,
      authorizationLedger: PersonalMemoryAuthorizationLedger()
    )
    executor = try HostToolExecutor(tools: [
      PersonalMemoryListTool(context: context),
      PersonalMemorySearchTool(context: context),
      PersonalMemoryUpsertTool(context: context),
      PersonalMemoryDeleteTool(context: context),
    ])
  }

  public func availableTools() async throws -> [ToolDefinition] {
    try await executor.availableTools()
  }

  public func authorizationRequest(
    for call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> AuthorizationRequest {
    do {
      return try await executor.authorizationRequest(for: call, in: context)
    } catch PersonalMemoryToolError.invalidArguments {
      throw ToolCallValidationError(
        recovery:
          "Check the memory tool schema and required arguments. No memory operation was dispatched."
      )
    } catch PersonalMemoryToolError.scopeMismatch {
      throw ToolCallValidationError(
        recovery:
          "Use the current host-bound memory scope \(boundScope.rawValue). No memory operation was dispatched."
      )
    }
  }

  public func execute(
    _ call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> ToolResult {
    try await executor.execute(call, in: context)
  }
}
