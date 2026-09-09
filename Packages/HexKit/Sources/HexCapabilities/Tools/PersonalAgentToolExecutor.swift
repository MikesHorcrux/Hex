import HexCore

/// Provider-neutral personal-agent tool surface. Inference providers only see tool definitions;
/// every host action still flows through the runtime's authorization provider before execution.
public struct PersonalAgentToolExecutor: ToolExecutor, Sendable {
  private let executor: HostToolExecutor

  public init(
    fileSystem: WorkspaceFileSystem,
    processExecutor: any ProcessExecuting,
    processConfiguration: ProcessExecutionConfiguration = .standard,
    processEnvironment: [String: String]? = nil,
    processAuthorizationConfiguration: CapabilityAuthorizationCenterConfiguration = .standard,
    codingWorkspace: CodingWorkspaceManager? = nil,
    processSessions: ProcessSessionManager? = nil
  ) throws {
    let applicationController = SystemMacApplicationController()
    let accessibilityController = SystemMacAccessibilityController()
    let addressValidator = SystemWebAddressValidator()
    let webFetcher = URLSessionWebFetcher(addressValidator: addressValidator)
    try self.init(
      fileSystem: fileSystem,
      processExecutor: processExecutor,
      applicationController: applicationController,
      accessibilityController: accessibilityController,
      addressValidator: addressValidator,
      webFetcher: webFetcher,
      processConfiguration: processConfiguration,
      processEnvironment: processEnvironment,
      processAuthorizationConfiguration: processAuthorizationConfiguration,
      codingWorkspace: codingWorkspace, processSessions: processSessions
    )
  }

  public init(
    fileSystem: WorkspaceFileSystem,
    processExecutor: any ProcessExecuting,
    applicationController: any MacApplicationControlling,
    accessibilityController: any MacAccessibilityControlling,
    addressValidator: any WebAddressValidating,
    webFetcher: any WebFetching,
    processConfiguration: ProcessExecutionConfiguration = .standard,
    processEnvironment: [String: String]? = nil,
    processAuthorizationConfiguration: CapabilityAuthorizationCenterConfiguration = .standard,
    codingWorkspace: CodingWorkspaceManager? = nil,
    processSessions: ProcessSessionManager? = nil
  ) throws {
    let observationLedger = MacAccessibilityObservationLedger()
    func tracked(_ tool: any HostTool) -> any HostTool {
      if let codingWorkspace, let processSessions {
        return CodingLegacyWriteTool(
          base: tool, manager: codingWorkspace, sessions: processSessions)
      }
      return tool
    }
    executor = try HostToolExecutor(tools: [
      MacAccessibilityActionTool(
        controller: accessibilityController, observationLedger: observationLedger),
      MacAccessibilitySnapshotTool(
        controller: accessibilityController, observationLedger: observationLedger),
      MacActivateApplicationTool(controller: applicationController),
      MacListApplicationsTool(controller: applicationController),
      ProcessRunTool(
        executor: processExecutor,
        configuration: processConfiguration,
        environment: processEnvironment,
        authorizationConfiguration: processAuthorizationConfiguration
      ),
      WebFetchTool(fetcher: webFetcher),
      WebOpenTool(
        addressValidator: addressValidator,
        applicationController: applicationController
      ),
      WebSearchTool(fetcher: webFetcher),
      WorkspaceListDirectoryTool(fileSystem: fileSystem),
      WorkspaceReadTextFileTool(fileSystem: fileSystem),
      tracked(WorkspaceReplaceTextTool(fileSystem: fileSystem)),
      WorkspaceSearchTextTool(fileSystem: fileSystem),
      tracked(WorkspaceWriteTextFileTool(fileSystem: fileSystem)),
    ])
  }

  public func availableTools() async throws -> [ToolDefinition] {
    try await executor.availableTools()
  }

  public func authorizationRequest(
    for call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> AuthorizationRequest {
    try await executor.authorizationRequest(for: call, in: context)
  }

  public func execute(
    _ call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> ToolResult {
    try await executor.execute(call, in: context)
  }
}
