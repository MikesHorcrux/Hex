import Foundation
import HexCapabilities
import HexCore
import HexGatewayKit
import HexIPC
import HexMCP
import HexPersistence
import Testing

@Suite("Controlled MCP gateway integration", .timeLimit(.minutes(1)))
struct HexGatewayControlledMCPIntegrationTests {
  @Test @MainActor
  func persistedAuthenticatedHTTPAndStdioSettingsDiscoverAndCallRealServers() async throws {
    let fixture = try ControlledMCPServerFixture()
    defer { fixture.cleanup() }
    let endpoint = try await fixture.start()
    let key = try HexSecretKey.mcpBearerToken(serverID: "remote", endpointURL: endpoint)
    let secretStore = SecretStore(values: [key: ControlledMCPServerFixture.token])
    let stdio = try ControlledMCPServerFixture.stdioConfiguration()
    let configuration = try await configuration(
      fixture: fixture,
      servers: [
        try HexResidentMCPServerSettings(
          serverID: "remote", transport: .streamableHTTP, endpointURL: endpoint,
          requiresBearerToken: true),
        try HexResidentMCPServerSettings(
          serverID: "local", transport: .stdio, executableURL: stdio.executableURL,
          arguments: stdio.arguments, workingDirectory: stdio.workingDirectory),
      ], secretStore: secretStore)

    #expect(configuration.mcpClientSessions.map(\.serverID) == ["local", "remote"])
    #expect(await secretStore.readKeys.isEmpty)
    let settingsBytes = try Data(contentsOf: fixture.root.appendingPathComponent("resident.json"))
    #expect(
      !String(decoding: settingsBytes, as: UTF8.self).contains(ControlledMCPServerFixture.token))
    let executors = try configuration.mcpClientSessions.map {
      try MCPManagedToolExecutor(session: $0)
    }
    do {
      for executor in executors {
        let tools = try await executor.availableTools()
        let tool = try #require(tools.first)
        #expect(tools.count == 1)
        let result = try await executor.execute(
          ToolCall(name: tool.name, arguments: ["operation": .string("setup")]),
          in: ToolExecutionContext(runID: AgentRunID()))
        #expect(result.status == .success)
        #expect(!result.content.isEmpty)
      }
      let events = try fixture.events()
      #expect(
        events.map { $0["method"] } == [
          "initialize", "notifications/initialized", "tools/list", "tools/call",
        ])
      #expect(events.allSatisfy { $0["authorized"] == "True" })
      #expect(await secretStore.readKeys == [key, key, key, key])
    } catch {
      for executor in executors { await executor.stop() }
      throw error
    }
    for executor in executors { await executor.stop() }
    #expect(try fixture.events().last?["method"] == "DELETE")
  }

  @Test(arguments: ["bad_token", "revoked", "malformed", "offline"]) @MainActor
  func brokenHTTPServerLeavesStdioToolsAndOrdinaryChatWorking(mode: String) async throws {
    let fixture = try ControlledMCPServerFixture()
    defer { fixture.cleanup() }
    let endpoint = try await fixture.start()
    if mode == "offline" { fixture.stopServer() }
    if mode == "revoked" || mode == "malformed" { try fixture.update(mode: mode) }
    let key = try HexSecretKey.mcpBearerToken(serverID: "remote", endpointURL: endpoint)
    let secretStore = SecretStore(values: [
      key: mode == "bad_token" ? "invalid-fixture-token" : ControlledMCPServerFixture.token
    ])
    let stdio = try ControlledMCPServerFixture.stdioConfiguration()
    let configuration = try await configuration(
      fixture: fixture,
      servers: [
        try HexResidentMCPServerSettings(
          serverID: "remote", transport: .streamableHTTP, endpointURL: endpoint,
          requiresBearerToken: true),
        try HexResidentMCPServerSettings(
          serverID: "local", transport: .stdio, executableURL: stdio.executableURL,
          arguments: stdio.arguments, workingDirectory: stdio.workingDirectory),
      ], secretStore: secretStore)
    let executors = try configuration.mcpClientSessions.map {
      try MCPManagedToolExecutor(session: $0)
    }
    let tools = try CompositeToolExecutor(executors: executors)
    do {
      #expect(try await tools.availableTools().map(\.name) == ["mcp_5_local_echo"])
      let failed = try #require(executors.first { $0.serverID == "remote" })
      #expect(await failed.currentState() == .unavailable)
      let expectedFailure: MCPManagedToolFailure =
        mode == "malformed"
        ? .invalidResponse
        : mode == "offline" ? .connectionFailed : .authenticationRejected
      #expect(await failed.healthSnapshot().failure == expectedFailure)
      let receipt = try await tools.execute(
        ToolCall(name: "mcp_5_local_echo", arguments: [:]),
        in: ToolExecutionContext(runID: AgentRunID()))
      #expect(receipt.status == .success)
      try await ordinaryChatCompletes(tools: tools, root: fixture.root)
      #expect(try fixture.events().filter { $0["method"] == "tools/call" }.isEmpty)
    } catch {
      for executor in executors { await executor.stop() }
      throw error
    }
    for executor in executors { await executor.stop() }
  }

  @Test(arguments: [false, true]) @MainActor
  func retainedTokenIsNeverReusedWithoutOptInOrForAChangedEndpoint(
    endpointChanged: Bool
  ) async throws {
    let fixture = try ControlledMCPServerFixture()
    defer { fixture.cleanup() }
    let originalEndpoint = try await fixture.start()
    let oldKey = try HexSecretKey.mcpBearerToken(serverID: "remote", endpointURL: originalEndpoint)
    let secretStore = SecretStore(values: [oldKey: ControlledMCPServerFixture.token])
    let endpoint =
      endpointChanged ? originalEndpoint.appendingPathComponent("changed") : originalEndpoint
    let configuration = try await configuration(
      fixture: fixture,
      servers: [
        try HexResidentMCPServerSettings(
          serverID: "remote", transport: .streamableHTTP, endpointURL: endpoint,
          requiresBearerToken: endpointChanged)
      ], secretStore: secretStore)
    let executor = try MCPManagedToolExecutor(
      session: #require(configuration.mcpClientSessions.first))
    do {
      #expect(try await executor.availableTools().isEmpty)
      #expect(await executor.healthSnapshot().failure == .authenticationRejected)
      #expect(!(await secretStore.readKeys).contains(oldKey))
      let events = try fixture.events()
      if endpointChanged {
        #expect(events.isEmpty)
        let newKey = try HexSecretKey.mcpBearerToken(serverID: "remote", endpointURL: endpoint)
        #expect(await secretStore.readKeys == [newKey])
      } else {
        #expect(await secretStore.readKeys.isEmpty)
        #expect(events.map { $0["method"] } == ["initialize"])
        #expect(events.allSatisfy { $0["authorized"] == "False" })
      }
    } catch {
      await executor.stop()
      throw error
    }
    await executor.stop()
  }

  @Test @MainActor
  func realHTTPReceiptSurvivesCatalogRemovalAndFutureCallsUseReplacement() async throws {
    let fixture = try ControlledMCPServerFixture()
    defer { fixture.cleanup() }
    let endpoint = try await fixture.start()
    let session = try httpSession(endpoint: endpoint)
    let executor = try MCPToolExecutor(sessions: [session])
    try await executor.start()
    try fixture.update(mode: "hold_call")
    let original = ToolCall(name: "mcp_6_remote_echo", arguments: ["operation": .string("first")])
    let task = Task {
      try await executor.execute(original, in: ToolExecutionContext(runID: AgentRunID()))
    }
    do {
      try await fixture.waitForCalls(1)
      try fixture.update(mode: "hold_call", tool: "replacement")
      try await executor.refreshCatalog()
      #expect(try await executor.availableTools().map(\.name) == ["mcp_6_remote_replacement"])
      try fixture.update(tool: "replacement")
      let result = try await task.value
      #expect(result.toolCallID == original.id)
      #expect(result.content.contains(.text("http receipt first")))
      await #expect(throws: (any Error).self) {
        try await executor.execute(original, in: ToolExecutionContext(runID: AgentRunID()))
      }
      #expect(try fixture.events().filter { $0["method"] == "tools/call" }.count == 1)
      let next = try await executor.execute(
        ToolCall(name: "mcp_6_remote_replacement", arguments: ["operation": .string("second")]),
        in: ToolExecutionContext(runID: AgentRunID()))
      #expect(next.content.contains(.text("http receipt second")))
    } catch {
      try? fixture.update()
      await executor.stop()
      _ = await task.result
      throw error
    }
    await executor.stop()
  }

  @Test @MainActor
  func unknownLengthJSONCannotPublishAValidPrefixBeforeTrailingGarbage() async throws {
    let fixture = try ControlledMCPServerFixture()
    defer { fixture.cleanup() }
    let endpoint = try await fixture.start()
    let session = try httpSession(endpoint: endpoint)
    do {
      try await session.connect()
      _ = try await session.listTools()
      try fixture.update(mode: "json_trailing_garbage")
      await #expect(throws: MCPClientSessionError.protocolViolation) {
        try await session.callTool(
          MCPRemoteToolCall(name: "echo", arguments: ["operation": .string("incomplete")]))
      }
      #expect(try fixture.events().filter { $0["method"] == "tools/call" }.count == 1)
    } catch {
      await session.disconnect()
      throw error
    }
    await session.disconnect()
  }

  @Test @MainActor
  func continuousHTTPKeepalivesCannotExtendTheRequestDeadline() async throws {
    let fixture = try ControlledMCPServerFixture()
    defer { fixture.cleanup() }
    let endpoint = try await fixture.start()
    let session = StreamableHTTPMCPClientSession(
      configuration: try MCPStreamableHTTPServerConfiguration(
        serverID: "remote", endpointURL: endpoint, requestTimeoutMilliseconds: 250),
      headerProvider: HeaderProvider())
    do {
      try await session.connect()
      try fixture.update(mode: "keepalive_until_timeout")
      let start = ContinuousClock.now
      await #expect(throws: MCPClientSessionError.requestTimedOut) {
        try await session.listTools()
      }
      #expect(start.duration(to: .now) < .seconds(2))
      #expect(try fixture.events().filter { $0["method"] == "tools/list" }.count == 1)
    } catch {
      await session.disconnect()
      throw error
    }
    await session.disconnect()
  }

  @Test @MainActor
  func liveHTTPStreamAnswersServerPingBeforeWaitingForTheFinalCatalog() async throws {
    let fixture = try ControlledMCPServerFixture()
    defer { fixture.cleanup() }
    let endpoint = try await fixture.start()
    let session = try httpSession(endpoint: endpoint)
    do {
      try await session.connect()
      try fixture.update(mode: "ping_gate")
      #expect(try await session.listTools().map(\.name) == ["echo"])
      let events = try fixture.events()
      let response = try #require(events.first { $0["method"] == "" })
      #expect(response["authorized"] == "True")
      #expect(response["protocol"] == "2025-11-25")
      #expect(response["session"]?.isEmpty == false)
      #expect(events.filter { $0["method"] == "tools/list" }.count == 1)
    } catch {
      await session.disconnect()
      throw error
    }
    await session.disconnect()
  }

  @Test @MainActor
  func droppedResponseIsNeverAutomaticallyReplayedDuringRecovery() async throws {
    let fixture = try ControlledMCPServerFixture()
    defer { fixture.cleanup() }
    let endpoint = try await fixture.start()
    let executor = try MCPManagedToolExecutor(session: httpSession(endpoint: endpoint))
    _ = try await executor.availableTools()
    try fixture.update(mode: "drop_call")
    do {
      await #expect(throws: (any Error).self) {
        try await executor.execute(
          ToolCall(name: "mcp_6_remote_echo", arguments: ["operation": .string("uncertain")]),
          in: ToolExecutionContext(runID: AgentRunID()))
      }
      #expect(try fixture.events().filter { $0["method"] == "tools/call" }.count == 1)
      try fixture.update()
      try await executor.refreshCatalog()
      #expect(try await executor.availableTools().count == 1)
      #expect(try fixture.events().filter { $0["method"] == "tools/call" }.count == 1)
      let receipt = try await executor.execute(
        ToolCall(name: "mcp_6_remote_echo", arguments: ["operation": .string("new-read")]),
        in: ToolExecutionContext(runID: AgentRunID()))
      #expect(receipt.content.contains(.text("http receipt new-read")))
      let calls = try fixture.events().filter { $0["method"] == "tools/call" }
      #expect(calls.compactMap { $0["operation"] } == ["uncertain", "new-read"])
      #expect(calls.first?["session"] != calls.last?["session"])
    } catch {
      await executor.stop()
      throw error
    }
    await executor.stop()
  }

  @Test @MainActor
  func realDroppedCallPersistsAnUncertainNonretryableGatewayFailure() async throws {
    let fixture = try ControlledMCPServerFixture()
    defer { fixture.cleanup() }
    let endpoint = try await fixture.start()
    try fixture.update(mode: "drop_call")
    let executor = try MCPManagedToolExecutor(session: httpSession(endpoint: endpoint))
    let call = ToolCall(
      name: "mcp_6_remote_echo", arguments: ["operation": .string("journal-uncertain")])
    let provider = GatewayTestInferenceProvider(toolCall: call)
    let journal = try await SQLiteAgentEventJournal.open(
      configuration: SQLiteAgentEventJournalConfiguration(
        databaseURL: fixture.root.appendingPathComponent("uncertain.sqlite")))
    let composition = try await HexGatewayComposition.open(
      configuration: HexGatewayCompositionConfiguration(
        journal: journal, inferenceProvider: provider, toolExecutor: executor,
        authorizationProvider: GatewayTestAuthorizationProvider()))
    do {
      let runID = AgentRunID()
      await #expect(throws: (any Error).self) {
        try await composition.runDriver.run(
          GatewayStartRunRequest(
            runID: runID, modelID: provider.modelID,
            initialMessages: [Message(role: .user, content: [.text("Perform the fixture action")])]
          )
        ) { _ in }
      }
      let events = try await journal.records(for: runID, after: nil, limit: 128).map(\.event)
      #expect(events.filter { if case .toolStarted = $0 { true } else { false } }.count == 1)
      #expect(!events.contains { if case .toolFinished = $0 { true } else { false } })
      #expect(!events.contains(.runCompleted))
      let failures = events.compactMap { event -> AgentFailure? in
        if case .runFailed(let failure) = event { return failure }
        return nil
      }
      let failure = try #require(failures.first)
      #expect(failures.count == 1)
      #expect(failure.message.contains("outcome is uncertain"))
      #expect(!failure.isRetryable)
      try fixture.update()
      try await executor.refreshCatalog()
      #expect(try await executor.availableTools().count == 1)
      let calls = try fixture.events().filter { $0["method"] == "tools/call" }
      #expect(calls.compactMap { $0["operation"] } == ["journal-uncertain"])
    } catch {
      await executor.stop()
      try? await composition.close()
      try? await journal.close()
      throw error
    }
    await executor.stop()
    try await composition.close()
    try await journal.close()
  }

  @Test @MainActor
  func revokedCredentialCanBeRepairedWithoutRestartingTheGateway() async throws {
    let fixture = try ControlledMCPServerFixture()
    defer { fixture.cleanup() }
    let endpoint = try await fixture.start()
    let key = try HexSecretKey.mcpBearerToken(serverID: "remote", endpointURL: endpoint)
    let secretStore = SecretStore(values: [key: ControlledMCPServerFixture.token])
    let configuration = try await configuration(
      fixture: fixture,
      servers: [
        try HexResidentMCPServerSettings(
          serverID: "remote", transport: .streamableHTTP, endpointURL: endpoint,
          requiresBearerToken: true)
      ], secretStore: secretStore)
    let executor = try MCPManagedToolExecutor(
      session: #require(configuration.mcpClientSessions.first))
    do {
      #expect(try await executor.availableTools().map(\.name) == ["mcp_6_remote_echo"])
      try await secretStore.save("expired-fixture-token", for: key)
      await #expect(throws: (any Error).self) { try await executor.refreshCatalog() }
      #expect(await executor.currentState() == .unavailable)
      #expect(await executor.healthSnapshot().failure == .authenticationRejected)
      try await secretStore.save(ControlledMCPServerFixture.token, for: key)
      try fixture.update(tool: "reconnected")
      try await executor.refreshCatalog()
      #expect(try await executor.availableTools().map(\.name) == ["mcp_6_remote_reconnected"])
      #expect(try fixture.events().filter { $0["method"] == "tools/call" }.isEmpty)
    } catch {
      await executor.stop()
      throw error
    }
    await executor.stop()
  }

  @Test @MainActor
  func cancellingARealDispatchedCallForbidsAnotherDispatchFromThatTask() async throws {
    let fixture = try ControlledMCPServerFixture()
    defer { fixture.cleanup() }
    let endpoint = try await fixture.start()
    let executor = try MCPManagedToolExecutor(session: httpSession(endpoint: endpoint))
    _ = try await executor.availableTools()
    try fixture.update(mode: "hold_call")
    let task = Task {
      let context = ToolExecutionContext(runID: AgentRunID())
      do {
        _ = try await executor.execute(
          ToolCall(name: "mcp_6_remote_echo", arguments: ["operation": .string("cancelled")]),
          in: context)
      } catch {}
      await #expect(throws: (any Error).self) {
        try await executor.execute(
          ToolCall(name: "mcp_6_remote_echo", arguments: ["operation": .string("forbidden")]),
          in: context)
      }
    }
    do {
      try await fixture.waitForCalls(1)
      task.cancel()
      await task.value
      try fixture.update()
      let calls = try fixture.events().filter { $0["method"] == "tools/call" }
      #expect(calls.compactMap { $0["operation"] } == ["cancelled"])
    } catch {
      task.cancel()
      try? fixture.update()
      await executor.stop()
      await task.value
      throw error
    }
    await executor.stop()
  }

  @Test @MainActor
  func reconnectRejectsDelayedOldSessionReceipt() async throws {
    let fixture = try ControlledMCPServerFixture()
    defer { fixture.cleanup() }
    let endpoint = try await fixture.start()
    let executor = try MCPToolExecutor(sessions: [httpSession(endpoint: endpoint)])
    try await executor.start()
    try fixture.update(mode: "hold_call")
    let task = Task {
      try await executor.execute(
        ToolCall(name: "mcp_6_remote_echo", arguments: ["operation": .string("old")]),
        in: ToolExecutionContext(runID: AgentRunID()))
    }
    do {
      try await fixture.waitForCalls(1)
      await executor.stop()
      try await executor.start()
      try fixture.update()
      if case .success = await task.result {
        Issue.record("Old session receipt crossed reconnect.")
      }
      let result = try await executor.execute(
        ToolCall(name: "mcp_6_remote_echo", arguments: ["operation": .string("current")]),
        in: ToolExecutionContext(runID: AgentRunID()))
      #expect(result.content.contains(.text("http receipt current")))
      let calls = try fixture.events().filter { $0["method"] == "tools/call" }
      #expect(calls.count == 2)
      #expect(calls.first?["session"] != calls.last?["session"])
    } catch {
      try? fixture.update()
      await executor.stop()
      _ = await task.result
      throw error
    }
    await executor.stop()
  }

  @MainActor
  private func configuration(
    fixture: ControlledMCPServerFixture, servers: [HexResidentMCPServerSettings],
    secretStore: SecretStore
  ) async throws -> HexGatewayResidentConfiguration {
    let paths = try HexResidentDataPaths(
      settingsURL: fixture.root.appendingPathComponent("resident.json"),
      databaseURL: fixture.root.appendingPathComponent("journal.sqlite"),
      heartbeatStoreURL: fixture.root.appendingPathComponent("heartbeats.json"))
    let settings = try HexResidentRuntimeSettings(
      modelID: "fixture-model", workspaceRoot: fixture.root, mcpServers: servers)
    let store = try JSONHexResidentRuntimeSettingsStore(fileURL: paths.settingsURL)
    try await store.save(settings)
    return try await HexGatewayResidentConfiguration.loadPersisted(
      paths: paths, settingsStore: store, secretStore: secretStore,
      inferenceBackendSettingsStore: InferenceSettingsStore())
  }

  private func httpSession(endpoint: URL) throws -> StreamableHTTPMCPClientSession {
    StreamableHTTPMCPClientSession(
      configuration: try MCPStreamableHTTPServerConfiguration(
        serverID: "remote", endpointURL: endpoint, requestTimeoutMilliseconds: 2_000),
      headerProvider: HeaderProvider())
  }

  private func ordinaryChatCompletes(tools: any ToolExecutor, root: URL) async throws {
    let journal = try await SQLiteAgentEventJournal.open(
      configuration: SQLiteAgentEventJournalConfiguration(
        databaseURL: root.appendingPathComponent("chat.sqlite")))
    let provider = GatewayTestInferenceProvider()
    let composition = try await HexGatewayComposition.open(
      configuration: HexGatewayCompositionConfiguration(
        journal: journal, inferenceProvider: provider, toolExecutor: tools,
        authorizationProvider: GatewayTestAuthorizationProvider()))
    do {
      let runID = AgentRunID()
      try await composition.runDriver.run(
        GatewayStartRunRequest(
          runID: runID, modelID: provider.modelID,
          initialMessages: [Message(role: .user, content: [.text("hello")])])
      ) { _ in }
      let records = try await journal.records(for: runID, after: nil, limit: 128)
      #expect(records.last?.event == .runCompleted)
      #expect(
        records.contains {
          if case .messageAppended(let message) = $0.event {
            return message.role == .assistant && message.content.contains(.text("done"))
          }
          return false
        })
    } catch {
      try? await composition.close()
      try? await journal.close()
      throw error
    }
    try await composition.close()
    try await journal.close()
  }

  private struct HeaderProvider: MCPHTTPHeaderProvider {
    func headers(for serverID: String) async throws -> [String: String] {
      ["Authorization": "Bearer hex-controlled-fixture-token"]
    }
  }

  private actor SecretStore: HexSecretStore {
    private var values: [HexSecretKey: String]
    private(set) var readKeys: [HexSecretKey] = []
    init(values: [HexSecretKey: String]) { self.values = values }
    func exists(_ key: HexSecretKey) async throws -> Bool {
      key == .openAIAPIKey || values[key] != nil
    }
    func secret(for key: HexSecretKey) async throws -> String {
      readKeys.append(key)
      guard let value = values[key] else { throw FixtureError.unexpectedSecretRead }
      return value
    }
    func save(_ secret: String, for key: HexSecretKey) async throws { values[key] = secret }
    func delete(_ key: HexSecretKey) async throws { values[key] = nil }
  }

  private actor InferenceSettingsStore: HexInferenceBackendSettingsStore {
    func load() async throws -> HexInferenceBackendSettings? {
      try HexInferenceBackendSettings(openAIModelID: "fixture-model")
    }
    func save(_ settings: HexInferenceBackendSettings) async throws {}
  }

  private enum FixtureError: Error { case unexpectedSecretRead }
}
