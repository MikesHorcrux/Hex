import Foundation
import HexCore

public actor LocalMCPClientSession: MCPClientSession {
  public nonisolated let serverID: String
  public private(set) var initialization: MCPSessionInitialization?

  private let configuration: MCPClientSessionConfiguration
  private let connection: any MCPJSONRPCConnection
  private var state = MCPClientSessionState.disconnected
  private var lifecycleGeneration = UInt64(0)
  private var discoveredToolTaskSupport: [String: MCPToolTaskSupport]?

  public init(configuration: MCPServerConfiguration) {
    self.serverID = configuration.serverID
    self.configuration = MCPClientSessionConfiguration(configuration)
    self.connection = MCPStdioJSONRPCConnection(configuration: configuration)
  }

  init(
    configuration: MCPServerConfiguration,
    connection: any MCPJSONRPCConnection
  ) {
    self.serverID = configuration.serverID
    self.configuration = MCPClientSessionConfiguration(configuration)
    self.connection = connection
  }

  init(
    configuration: MCPClientSessionConfiguration,
    connection: any MCPJSONRPCConnection
  ) {
    self.serverID = configuration.serverID
    self.configuration = configuration
    self.connection = connection
  }

  public func connect() async throws {
    try Task.checkCancellation()
    guard case .disconnected = state else {
      throw MCPClientSessionError.alreadyConnected
    }
    guard lifecycleGeneration < UInt64.max else {
      throw MCPClientSessionError.limitExceeded
    }
    lifecycleGeneration += 1
    let generation = lifecycleGeneration
    state = .connecting
    do {
      try await connection.connect()
      try requireConnecting(generation: generation)
      let result = try await connection.request(
        method: "initialize",
        params: .object([
          "protocolVersion": .string(MCPProtocolVersion.preferred.rawValue),
          "capabilities": .object([:]),
          "clientInfo": .object([
            "name": .string(configuration.clientName),
            "version": .string(configuration.clientVersion),
          ]),
        ])
      )
      try requireConnecting(generation: generation)
      let decoded = try MCPSessionInitializationDecoder.decode(result)
      try await connection.notify(method: "notifications/initialized", params: nil)
      try requireConnecting(generation: generation)
      initialization = decoded
      discoveredToolTaskSupport = nil
      state = .ready
    } catch {
      if lifecycleGeneration == generation {
        initialization = nil
        discoveredToolTaskSupport = nil
        state = .disconnected
        await connection.disconnect()
      }
      throw error
    }
  }

  public func disconnect() async {
    if lifecycleGeneration < UInt64.max {
      lifecycleGeneration += 1
    }
    initialization = nil
    discoveredToolTaskSupport = nil
    state = .disconnected
    await connection.disconnect()
  }

  public func listTools() async throws -> [MCPRemoteTool] {
    let generation = try readyGeneration()
    var tools: [MCPRemoteTool] = []
    var cursor: String?
    var seenCursors = Set<String>()
    var seenToolNames = Set<String>()
    let supportsTaskAugmentedToolCalls =
      initialization?.protocolVersion == .november2025
      && initialization?.supportsTaskAugmentedToolCalls == true
    discoveredToolTaskSupport = nil

    for _ in 0..<configuration.maximumToolPages {
      try Task.checkCancellation()
      let params: JSONValue =
        if let cursor {
          .object(["cursor": .string(cursor)])
        } else {
          .object([:])
        }
      let response = try await performRequest(method: "tools/list", params: params)
      try requireReady(generation: generation)
      let page: MCPToolPage
      do {
        page = try MCPToolPageDecoder.decode(
          response,
          remainingToolCapacity: configuration.maximumTools - tools.count,
          supportsTaskAugmentedToolCalls: supportsTaskAugmentedToolCalls
        )
      } catch {
        await invalidate()
        throw error
      }
      for tool in page.tools {
        guard seenToolNames.insert(tool.name).inserted else {
          await invalidate()
          throw MCPClientSessionError.protocolViolation
        }
        tools.append(tool)
      }
      guard let nextCursor = page.nextCursor else {
        discoveredToolTaskSupport = Dictionary(
          uniqueKeysWithValues: tools.map { ($0.name, $0.taskSupport) }
        )
        return tools.filter { !$0.requiresTaskExecution }
      }
      guard seenCursors.insert(nextCursor).inserted else {
        await invalidate()
        throw MCPClientSessionError.protocolViolation
      }
      cursor = nextCursor
    }

    await invalidate()
    throw MCPClientSessionError.limitExceeded
  }

  public func callTool(_ call: MCPRemoteToolCall) async throws -> MCPRemoteToolResult {
    let generation = try readyGeneration()
    guard MCPToolCatalogBuilder.isValidToolName(call.name) else {
      throw MCPClientSessionError.protocolViolation
    }
    guard
      let taskSupport = discoveredToolTaskSupport?[call.name],
      taskSupport != .required
    else {
      throw MCPClientSessionError.toolsUnavailable
    }
    guard
      MCPJSONValueValidator.isValid(
        .object(call.arguments),
        maximumStringBytes: configuration.maximumArgumentsBytes,
        maximumEstimatedBytes: configuration.maximumArgumentsBytes
      ),
      let encodedArguments = try? JSONEncoder().encode(call.arguments),
      encodedArguments.count <= configuration.maximumArgumentsBytes
    else {
      throw MCPClientSessionError.limitExceeded
    }
    let response = try await performRequest(
      method: "tools/call",
      params: .object([
        "name": .string(call.name),
        "arguments": .object(call.arguments),
      ])
    )
    try requireReady(generation: generation)
    do {
      return try MCPRemoteToolResultDecoder.decode(
        response,
        maximumContentItems: configuration.maximumContentItems
      )
    } catch {
      await invalidate()
      throw error
    }
  }

  private func readyGeneration() throws -> UInt64 {
    try Task.checkCancellation()
    guard case .ready = state else {
      throw MCPClientSessionError.notConnected
    }
    return lifecycleGeneration
  }

  private func requireReady(generation: UInt64) throws {
    try Task.checkCancellation()
    guard lifecycleGeneration == generation, case .ready = state else {
      throw MCPClientSessionError.connectionClosed
    }
  }

  private func requireConnecting(generation: UInt64) throws {
    try Task.checkCancellation()
    guard lifecycleGeneration == generation, case .connecting = state else {
      throw MCPClientSessionError.connectionClosed
    }
  }

  private func performRequest(
    method: String,
    params: JSONValue
  ) async throws -> JSONValue {
    do {
      return try await connection.request(method: method, params: params)
    } catch is CancellationError {
      await invalidate()
      throw CancellationError()
    } catch let error as MCPClientSessionError {
      if case .remoteError = error {
        throw error
      }
      await invalidate()
      throw error
    } catch {
      await invalidate()
      throw error
    }
  }

  private func invalidate() async {
    if lifecycleGeneration < UInt64.max {
      lifecycleGeneration += 1
    }
    initialization = nil
    discoveredToolTaskSupport = nil
    state = .disconnected
    await connection.disconnect()
  }
}
