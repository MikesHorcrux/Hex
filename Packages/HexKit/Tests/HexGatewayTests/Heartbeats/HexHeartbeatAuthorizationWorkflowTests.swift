import Foundation
import HexCapabilities
import HexCore
import HexIPC
import HexPersistence
import Testing

@testable import HexGatewayKit

@Suite("Scheduled authorization through the real runtime")
struct HexHeartbeatAuthorizationWorkflowTests {
  @Test(arguments: [GrantMode.fullAccess, .storedGrant, .missingGrant])
  func actualPromptBoundaryDeterminesWhetherScheduledWorkCanProceed(_ mode: GrantMode) async throws
  {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("hex-heartbeat-authorization-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let tool = CapturingTool()
    let call = ToolCall(
      id: ToolCallID(rawValue: "scheduled-probe"), name: "scheduled_probe", arguments: [:])
    let provider = GatewayTestInferenceProvider(toolCall: call)
    let broker = HexGatewayAuthorizationBroker()
    let policy = HexHeartbeatAuthorizationPolicy(interactivePrompter: broker)
    let grants = VolatileAuthorizationGrantStore()
    if mode == .storedGrant {
      await grants.insert(
        AuthorizationGrantKey(
          capability: CapabilityID(rawValue: "tool.scheduled_probe"), operation: "execute",
          resource: nil))
    }
    let center = CapabilityAuthorizationCenter(
      prompter: policy, persistentStore: grants,
      authorizationMode: mode == .fullAccess ? .fullAccess : .askEveryTime)
    let composition = try await HexGatewayComposition.open(
      configuration: HexGatewayCompositionConfiguration(
        journalConfiguration: SQLiteAgentEventJournalConfiguration(
          databaseURL: directory.appendingPathComponent("journal.sqlite")),
        inferenceProvider: provider, toolExecutor: tool,
        authorizationProvider: HexHeartbeatAuthorizationProvider(base: center, policy: policy)))
    let client = HexGatewayClient(transport: composition.transport)
    do {
      _ = try await client.connect()
      let runner = try HexGatewayHeartbeatRunner(
        client: client, authorizationPolicy: policy, modelID: provider.modelID,
        workspaceRoot: directory,
        configuration: HexHeartbeatSchedulerConfiguration(
          leaseDurationSeconds: 10, runTimeoutSeconds: 5))
      let result = try await runner.run(executionRequest())
      let authorization = try #require(await tool.request)
      let records = try await composition.journal.records(
        for: authorization.runID, after: nil, limit: 128)
      #expect(
        records.contains {
          if case .authorizationRequested = $0.event { return true }
          return false
        })
      #expect(!(await broker.isPending(authorization.id)))
      #expect(await policy.registrationCount == 0)
      if mode == .missingGrant {
        guard case .failed(let failure) = result else {
          Issue.record(
            "A missing grant must stop the background run, not suspend an interactive prompt.")
          try await client.disconnect()
          try await composition.close()
          return
        }
        #expect(failure.code == .authorizationRequired)
        #expect(!failure.retryable)
        #expect(await tool.executionCount == 0)
        #expect(
          !records.contains {
            if case .authorizationDecided = $0.event { return true }
            return false
          })
        #expect(
          !records.contains {
            if case .toolStarted = $0.event { return true }
            return false
          })
        let skipped = records.compactMap { record -> ToolResult? in
          if case .toolFinished(let result) = record.event { return result }
          return nil
        }
        #expect(skipped.map(\.toolCallID) == [call.id])
        #expect(skipped.allSatisfy { $0.notExecutedReason == .runStopped })
        #expect(
          records.last.map {
            if case .runFailed = $0.event { return true }
            return false
          } == true)
      } else {
        #expect(result == .succeeded)
        #expect(await tool.executionCount == 1)
        #expect(
          records.contains {
            if case .authorizationDecided(_, .allow) = $0.event { return true }
            return false
          })
        #expect(records.last?.event == .runCompleted)
      }
      try await client.disconnect()
      try await composition.close()
    } catch {
      try? await client.disconnect()
      try? await composition.close()
      throw error
    }
  }

  private func executionRequest() throws -> HexHeartbeatExecutionRequest {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let schedule = try HexHeartbeatSchedule(
      name: "scheduled probe", instruction: "Use scheduled_probe and report its result.",
      intervalSeconds: 60, nextDueAt: now)
    let occurrence = schedule.occurrence()
    return HexHeartbeatExecutionRequest(
      schedule: schedule, occurrence: occurrence,
      lease: HexHeartbeatLease(
        occurrence: occurrence, claimedAt: now, expiresAt: now.addingTimeInterval(10),
        runID: AgentRunID()))
  }

  enum GrantMode: Sendable { case fullAccess, storedGrant, missingGrant }

  private actor CapturingTool: ToolExecutor {
    private(set) var request: AuthorizationRequest?
    private(set) var executionCount = 0

    func availableTools() -> [ToolDefinition] {
      [
        ToolDefinition(
          name: "scheduled_probe",
          description: "Records execution for a scheduled authorization check.",
          inputSchema: ["type": .string("object")])
      ]
    }

    func authorizationRequest(for call: ToolCall, in context: ToolExecutionContext)
      -> AuthorizationRequest
    {
      let request = AuthorizationRequest(
        runID: context.runID, toolCallID: call.id,
        capability: CapabilityID(rawValue: "tool.scheduled_probe"), operation: "execute",
        explanation: "Run the scheduled probe.")
      self.request = request
      return request
    }

    func execute(_ call: ToolCall, in context: ToolExecutionContext) -> ToolResult {
      executionCount += 1
      return ToolResult(
        toolCallID: call.id, status: .success, output: .string("scheduled probe complete"))
    }
  }
}
