import Foundation
import HexCore
import HexIPC
import HexMCP
import Testing

@testable import HexGatewayKit

@Suite("Resident tool connection control")
struct HexGatewayToolServerControllerTests {
  @Test
  func readsDoNotConnectAndExplicitRefreshTouchesOnlyTheSelectedServer() async throws {
    let first = Session(serverID: "alpha")
    let second = Session(serverID: "beta")
    let firstExecutor = try MCPManagedToolExecutor(session: first)
    let secondExecutor = try MCPManagedToolExecutor(session: second)
    let controller = try HexGatewayToolServerController(
      executors: [secondExecutor, firstExecutor])

    let initial = try await controller.health()
    #expect(initial.servers.map(\.serverID) == ["alpha", "beta"])
    #expect(initial.servers.allSatisfy { $0.state == .disconnected })
    #expect(await first.connectionCount == 0)
    #expect(await second.connectionCount == 0)

    let checked = try await controller.refresh(GatewayToolServerRequest(serverID: "alpha"))
    #expect(checked.state == .ready)
    #expect(checked.availableToolCount == 1)
    #expect(checked.failure == nil)
    #expect(try await controller.health().servers.first == checked)
    #expect(await first.connectionCount == 1)
    #expect(await first.listCount == 1)
    #expect(await first.callCount == 0)
    #expect(await second.connectionCount == 0)

    await #expect(throws: GatewayFailure.self) {
      try await controller.refresh(GatewayToolServerRequest(serverID: "not_enabled"))
    }
    #expect(await first.connectionCount == 1)
    #expect(await second.connectionCount == 0)
    await firstExecutor.stop()
    await secondExecutor.stop()
  }

  @Test
  func failedConnectionReturnsSanitizedResidentHealthWithoutExecutingATool() async throws {
    let session = Session(serverID: "broken", rejectsCatalog: true)
    let executor = try MCPManagedToolExecutor(session: session)
    let controller = try HexGatewayToolServerController(executors: [executor])
    let status = try await controller.refresh(GatewayToolServerRequest(serverID: "broken"))
    #expect(status.state == .unavailable)
    #expect(status.failure == .invalidResponse)
    #expect(status.availableToolCount == nil)
    #expect(await session.connectionCount == 1)
    #expect(await session.callCount == 0)
    #expect(try await controller.health().servers == [status])
    await executor.stop()
  }

  @Test
  func emptyOrDuplicateRuntimeIdentitiesAreNotInvented() async throws {
    #expect(try await HexGatewayToolServerController(executors: []).health().servers.isEmpty)
    let first = try MCPManagedToolExecutor(session: Session(serverID: "same"))
    let second = try MCPManagedToolExecutor(session: Session(serverID: "same"))
    #expect(throws: GatewayFailure.self) {
      try HexGatewayToolServerController(executors: [first, second])
    }
  }

  @Test
  func statusCarriesConfiguredTransportWithoutInferringItFromServerName() async throws {
    let executor = try MCPManagedToolExecutor(session: Session(serverID: "playwright"))
    let custom = try HexResidentMCPServerSettings(
      serverID: "playwright", transport: .streamableHTTP,
      endpointURL: #require(URL(string: "http://127.0.0.1:8080/mcp")))
    let controller = try HexGatewayToolServerController(executors: [executor], settings: [custom])
    let status = try #require(await controller.health().servers.first)
    #expect(status.transport == .streamableHTTP)
    let encoded = try JSONEncoder().encode(status)
    #expect(try JSONDecoder().decode(GatewayToolServerStatus.self, from: encoded) == status)
    let unknown = try HexGatewayToolServerController(executors: [executor])
    #expect(try await unknown.health().servers.first?.transport == nil)
    let managed = try HexGatewayToolServerController(
      executors: [executor], settings: [.playwright()])
    #expect(try await managed.health().servers.first?.transport == .playwright)
    #expect(throws: GatewayFailure.self) {
      try HexGatewayToolServerController(executors: [executor], settings: [.xcode()])
    }
    #expect(throws: GatewayFailure.self) {
      try GatewayToolServerStatus(
        serverID: "custom", state: .disconnected,
        transport: .playwright
      ).validated()
    }
    let legacy = Data(#"{"serverID":"playwright","state":"disconnected"}"#.utf8)
    #expect(try JSONDecoder().decode(GatewayToolServerStatus.self, from: legacy).transport == nil)
  }

  private actor Session: MCPClientSession {
    nonisolated let serverID: String
    let rejectsCatalog: Bool
    private(set) var connectionCount = 0
    private(set) var listCount = 0
    private(set) var callCount = 0

    init(serverID: String, rejectsCatalog: Bool = false) {
      self.serverID = serverID
      self.rejectsCatalog = rejectsCatalog
    }

    func connect() async throws { connectionCount += 1 }
    func disconnect() async {}

    func listTools() async throws -> [MCPRemoteTool] {
      listCount += 1
      if rejectsCatalog { throw MCPClientSessionError.protocolViolation }
      return [MCPRemoteTool(name: "read", inputSchema: ["type": .string("object")])]
    }

    func callTool(_ call: MCPRemoteToolCall) async throws -> MCPRemoteToolResult {
      callCount += 1
      return MCPRemoteToolResult(
        content: [.text("not needed for a connection check")], isError: false)
    }
  }
}
