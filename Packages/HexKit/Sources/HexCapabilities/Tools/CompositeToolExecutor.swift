import HexCore

/// Presents multiple independently owned tool executors as one runtime surface.
///
/// Definitions are rebuilt on every discovery boundary so reconnecting dynamic executors can add
/// or remove tools without mutating the agent runtime or its provider adapters.
public actor CompositeToolExecutor: ToolExecutor {
  private static let maximumExecutors = 32
  private static let maximumTools = 4_096

  private let executors: [any ToolExecutor]
  private var routes: [String: Int] = [:]

  public init(executors: [any ToolExecutor]) throws {
    guard !executors.isEmpty, executors.count <= Self.maximumExecutors else {
      throw CompositeToolExecutorError.invalidExecutorCount
    }
    self.executors = executors
  }

  public func availableTools() async throws -> [ToolDefinition] {
    try Task.checkCancellation()
    let executors = self.executors
    let snapshots = try await withThrowingTaskGroup(
      of: CompositeToolExecutorDiscoverySnapshot.self,
      returning: [CompositeToolExecutorDiscoverySnapshot].self
    ) { group in
      for (index, executor) in executors.enumerated() {
        group.addTask {
          try Task.checkCancellation()
          return CompositeToolExecutorDiscoverySnapshot(
            executorIndex: index,
            definitions: try await executor.availableTools()
          )
        }
      }

      var snapshots: [CompositeToolExecutorDiscoverySnapshot] = []
      snapshots.reserveCapacity(executors.count)
      for try await snapshot in group {
        snapshots.append(snapshot)
      }
      return snapshots.sorted { $0.executorIndex < $1.executorIndex }
    }
    try Task.checkCancellation()

    var definitions: [ToolDefinition] = []
    var candidateRoutes: [String: Int] = [:]

    for snapshot in snapshots {
      let executorDefinitions = snapshot.definitions
      let (nextCount, overflowed) = definitions.count.addingReportingOverflow(
        executorDefinitions.count
      )
      guard !overflowed, nextCount <= Self.maximumTools else {
        throw CompositeToolExecutorError.tooManyTools
      }
      for definition in executorDefinitions {
        guard candidateRoutes[definition.name] == nil else {
          throw CompositeToolExecutorError.duplicateTool(definition.name)
        }
        definitions.append(definition)
        candidateRoutes[definition.name] = snapshot.executorIndex
      }
    }

    definitions.sort { $0.name < $1.name }
    routes = candidateRoutes
    return definitions
  }

  public func authorizationRequest(
    for call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> AuthorizationRequest {
    try Task.checkCancellation()
    guard let index = routes[call.name], executors.indices.contains(index) else {
      throw CompositeToolExecutorError.unknownTool
    }
    return try await executors[index].authorizationRequest(for: call, in: context)
  }

  public func execute(
    _ call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> ToolResult {
    try Task.checkCancellation()
    guard let index = routes[call.name], executors.indices.contains(index) else {
      throw CompositeToolExecutorError.unknownTool
    }
    return try await executors[index].execute(call, in: context)
  }
}
