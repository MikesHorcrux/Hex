import Foundation
import HexCore

actor MCPStreamableHTTPJSONRPCConnection: MCPJSONRPCConnection {
  static let maximumActiveRequests = 64

  private let configuration: MCPStreamableHTTPServerConfiguration
  private let headerProvider: any MCPHTTPHeaderProvider
  private let transport: any MCPHTTPTransport
  private var state = MCPConnectionState.disconnected
  private var generation = UInt64(0)
  private var nextRequestID = Int64(1)
  private var activeRequestCount = 0
  private var sessionID: String?
  private var negotiatedProtocolVersion: MCPProtocolVersion?

  init(
    configuration: MCPStreamableHTTPServerConfiguration,
    headerProvider: any MCPHTTPHeaderProvider = MCPEmptyHTTPHeaderProvider()
  ) {
    self.configuration = configuration
    self.headerProvider = headerProvider
    self.transport = URLSessionMCPHTTPTransport()
  }

  init(
    configuration: MCPStreamableHTTPServerConfiguration,
    headerProvider: any MCPHTTPHeaderProvider,
    transport: any MCPHTTPTransport
  ) {
    self.configuration = configuration
    self.headerProvider = headerProvider
    self.transport = transport
  }

  func connect() async throws {
    try Task.checkCancellation()
    guard state == .disconnected else {
      throw MCPClientSessionError.alreadyConnected
    }
    guard generation < UInt64.max else {
      throw MCPClientSessionError.limitExceeded
    }
    generation += 1
    nextRequestID = 1
    sessionID = nil
    negotiatedProtocolVersion = nil
    state = .connected
  }

  func disconnect() async {
    let closingSessionID = sessionID
    let closingProtocolVersion = negotiatedProtocolVersion
    if generation < UInt64.max {
      generation += 1
    }
    state = .disconnected
    sessionID = nil
    negotiatedProtocolVersion = nil
    guard let closingSessionID else { return }
    await sendDelete(
      sessionID: closingSessionID,
      protocolVersion: closingProtocolVersion
    )
  }

  func request(method: String, params: JSONValue) async throws -> JSONValue {
    try Task.checkCancellation()
    guard
      state == .connected,
      activeRequestCount < Self.maximumActiveRequests,
      MCPStdioJSONRPCConnection.validMethod(method),
      nextRequestID < Int64.max
    else {
      throw MCPClientSessionError.connectionClosed
    }
    let requestID = nextRequestID
    nextRequestID += 1
    let requestGeneration = generation
    activeRequestCount += 1
    defer { activeRequestCount -= 1 }

    let message = JSONValue.object([
      "jsonrpc": .string("2.0"),
      "id": .integer(requestID),
      "method": .string(method),
      "params": params,
    ])
    let response = try await sendPOST(
      message, generation: requestGeneration, requestID: requestID,
      initializesSession: method == "initialize")
    // A complete returned response may be a receipt for an action that already happened.
    // Cancellation stops new dispatch; only lifecycle replacement invalidates this receipt.
    try requireSameConnection(generation: requestGeneration)
    guard response.statusCode == 200 else {
      try await handleUnexpectedStatus(response.statusCode, generation: requestGeneration)
    }
    if method == "initialize" {
      try captureSessionID(from: response)
    }
    let messages = try MCPStreamableHTTPResponseDecoder.decode(
      response,
      maximumMessageBytes: configuration.maximumMessageBytes,
      maximumSSEEvents: configuration.maximumSSEEvents
    )
    let result = try await result(
      from: messages,
      requestID: requestID,
      generation: requestGeneration,
      respondToServerRequests: !response.isEventStream
    )
    if method == "initialize" {
      guard
        let rawVersion = result.mcpObject?["protocolVersion"]?.mcpString,
        let version = MCPProtocolVersion(rawValue: rawVersion)
      else {
        throw MCPClientSessionError.unsupportedProtocolVersion
      }
      negotiatedProtocolVersion = version
    }
    return result
  }

  func notify(method: String, params: JSONValue?) async throws {
    try Task.checkCancellation()
    guard
      state == .connected,
      activeRequestCount < Self.maximumActiveRequests,
      MCPStdioJSONRPCConnection.validMethod(method)
    else {
      throw MCPClientSessionError.connectionClosed
    }
    let requestGeneration = generation
    activeRequestCount += 1
    defer { activeRequestCount -= 1 }
    var object: [String: JSONValue] = [
      "jsonrpc": .string("2.0"),
      "method": .string(method),
    ]
    if let params { object["params"] = params }
    let response = try await sendPOST(.object(object), generation: requestGeneration)
    try requireConnected(generation: requestGeneration)
    guard response.statusCode == 202, response.body.isEmpty else {
      try await handleUnexpectedStatus(response.statusCode, generation: requestGeneration)
    }
  }

  private func sendPOST(
    _ message: JSONValue,
    generation: UInt64,
    requestID: Int64? = nil,
    initializesSession: Bool = false
  ) async throws -> MCPHTTPResponse {
    let body = try encodedMessage(message)
    let customHeaders = try await headerProvider.headers(for: configuration.serverID)
    try requireConnected(generation: generation)
    let normalizedHeaders = try MCPHTTPHeaderValidator.validate(customHeaders)
    var request = URLRequest(url: configuration.endpointURL)
    request.httpMethod = "POST"
    request.timeoutInterval = TimeInterval(configuration.requestTimeoutMilliseconds) / 1_000
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(
      "application/json, text/event-stream",
      forHTTPHeaderField: "Accept"
    )
    if let sessionID {
      request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id")
    }
    if let negotiatedProtocolVersion {
      request.setValue(
        negotiatedProtocolVersion.rawValue,
        forHTTPHeaderField: "MCP-Protocol-Version"
      )
    }
    for (name, value) in normalizedHeaders {
      request.setValue(value, forHTTPHeaderField: name)
    }
    let response: MCPHTTPResponse
    if let requestID {
      response = try await transport.send(
        request, maximumResponseBytes: configuration.maximumMessageBytes,
        maximumSSEEvents: configuration.maximumSSEEvents
      ) { message, headers in
        try await self.receiveSSEMessage(
          message, headers: headers, requestID: requestID, generation: generation,
          initializesSession: initializesSession)
      }
    } else {
      response = try await transport.send(
        request, maximumResponseBytes: configuration.maximumMessageBytes)
    }
    try requireSameConnection(generation: generation)
    guard response.finalURL == configuration.endpointURL else {
      throw MCPClientSessionError.protocolViolation
    }
    return response
  }

  private func result(
    from messages: [JSONValue],
    requestID: Int64,
    generation: UInt64,
    respondToServerRequests: Bool = true
  ) async throws -> JSONValue {
    var matchedResult: JSONValue?
    var matchedError: MCPClientSessionError?
    var serverResponses: [JSONValue] = []
    for message in messages {
      guard
        let object = message.mcpObject,
        object["jsonrpc"] == .string("2.0")
      else {
        throw MCPClientSessionError.protocolViolation
      }
      if object["method"] != nil {
        if let response = try serverResponse(for: object), respondToServerRequests {
          serverResponses.append(response)
        }
        continue
      }
      guard object["id"]?.mcpInteger == requestID else {
        throw MCPClientSessionError.protocolViolation
      }
      guard matchedResult == nil, matchedError == nil else {
        throw MCPClientSessionError.protocolViolation
      }
      let hasResult = object["result"] != nil
      let hasError = object["error"] != nil
      guard hasResult != hasError else {
        throw MCPClientSessionError.protocolViolation
      }
      if let value = object["result"] {
        matchedResult = value
      } else {
        guard
          let errorObject = object["error"]?.mcpObject,
          let code = errorObject["code"]?.mcpInteger,
          let message = errorObject["message"]?.mcpString,
          !message.isEmpty,
          message.utf8.count <= 8_192
        else {
          throw MCPClientSessionError.protocolViolation
        }
        matchedError = .remoteError(code: code)
      }
    }
    for response in serverResponses {
      try await sendServerResponse(response, generation: generation)
    }
    if let matchedError { throw matchedError }
    guard let matchedResult else {
      throw MCPClientSessionError.protocolViolation
    }
    return matchedResult
  }

  private func receiveSSEMessage(
    _ message: JSONValue, headers: [String: String], requestID: Int64,
    generation: UInt64, initializesSession: Bool
  ) async throws -> Bool {
    try requireSameConnection(generation: generation)
    if initializesSession { try captureSessionID(from: headers) }
    guard let object = message.mcpObject, object["jsonrpc"] == .string("2.0") else {
      throw MCPClientSessionError.protocolViolation
    }
    if object["method"] != nil {
      if let response = try serverResponse(for: object) {
        // Peer replies are new dispatch. Cancellation cannot authorize one while preserving a
        // later terminal receipt from the already returned stream.
        if !Task.isCancelled { try await sendServerResponse(response, generation: generation) }
      }
      return false
    }
    _ = try await result(
      from: [message], requestID: requestID, generation: generation,
      respondToServerRequests: false)
    return true
  }

  private func serverResponse(for object: [String: JSONValue]) throws -> JSONValue? {
    guard let method = object["method"]?.mcpString,
      MCPStdioJSONRPCConnection.validMethod(method),
      object["result"] == nil, object["error"] == nil,
      object["params"] == nil || object["params"]?.mcpObject != nil
    else { throw MCPClientSessionError.protocolViolation }
    guard let requestID = object["id"] else { return nil }
    guard Self.isValidServerRequestID(requestID) else {
      throw MCPClientSessionError.protocolViolation
    }
    if method == "ping" {
      return .object([
        "jsonrpc": .string("2.0"), "id": requestID, "result": .object([:]),
      ])
    }
    return .object([
      "jsonrpc": .string("2.0"), "id": requestID,
      "error": .object([
        "code": .integer(-32_601),
        "message": .string("Method not supported by this client."),
      ]),
    ])
  }

  private func sendServerResponse(
    _ message: JSONValue,
    generation: UInt64
  ) async throws {
    let response = try await sendPOST(message, generation: generation)
    guard response.statusCode == 202, response.body.isEmpty else {
      try await handleUnexpectedStatus(response.statusCode, generation: generation)
    }
  }

  private func encodedMessage(_ value: JSONValue) throws -> Data {
    guard
      MCPJSONValueValidator.isValid(
        value,
        maximumStringBytes: configuration.maximumMessageBytes,
        maximumEstimatedBytes: configuration.maximumMessageBytes
      )
    else {
      throw MCPClientSessionError.limitExceeded
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    guard data.count <= configuration.maximumMessageBytes else {
      throw MCPClientSessionError.limitExceeded
    }
    return data
  }

  private func captureSessionID(from response: MCPHTTPResponse) throws {
    try captureSessionID(from: response.headers)
  }

  private func captureSessionID(from headers: [String: String]) throws {
    guard let value = headers["mcp-session-id"] else { return }
    guard
      !value.isEmpty,
      value.utf8.count <= 1_024,
      value.utf8.allSatisfy({ (0x21...0x7E).contains($0) })
    else {
      throw MCPClientSessionError.protocolViolation
    }
    sessionID = value
  }

  private func handleUnexpectedStatus(
    _ statusCode: Int,
    generation: UInt64
  ) async throws -> Never {
    if statusCode == 401 || statusCode == 403 {
      throw MCPClientSessionError.authenticationRejected
    }
    if statusCode == 404, sessionID != nil, self.generation == generation {
      sessionID = nil
      negotiatedProtocolVersion = nil
      state = .disconnected
      throw MCPClientSessionError.connectionClosed
    }
    guard (100...599).contains(statusCode) else {
      throw MCPClientSessionError.protocolViolation
    }
    throw MCPClientSessionError.connectionClosed
  }

  private func requireConnected(generation: UInt64) throws {
    try Task.checkCancellation()
    try requireSameConnection(generation: generation)
  }

  private func requireSameConnection(generation: UInt64) throws {
    guard self.generation == generation, state == .connected else {
      throw MCPClientSessionError.connectionClosed
    }
  }

  private func sendDelete(
    sessionID: String,
    protocolVersion: MCPProtocolVersion?
  ) async {
    do {
      let customHeaders = try await headerProvider.headers(for: configuration.serverID)
      let normalizedHeaders = try MCPHTTPHeaderValidator.validate(customHeaders)
      var request = URLRequest(url: configuration.endpointURL)
      request.httpMethod = "DELETE"
      request.timeoutInterval = TimeInterval(configuration.requestTimeoutMilliseconds) / 1_000
      request.setValue(
        "application/json, text/event-stream",
        forHTTPHeaderField: "Accept"
      )
      request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id")
      if let protocolVersion {
        request.setValue(
          protocolVersion.rawValue,
          forHTTPHeaderField: "MCP-Protocol-Version"
        )
      }
      for (name, value) in normalizedHeaders {
        request.setValue(value, forHTTPHeaderField: name)
      }
      _ = try await transport.send(
        request,
        maximumResponseBytes: configuration.maximumMessageBytes
      )
    } catch {
      return
    }
  }

  private static func isValidServerRequestID(_ value: JSONValue) -> Bool {
    switch value {
    case .integer:
      true
    case .string(let id):
      id.utf8.count <= 128 && !id.contains("\0")
    case .number(let number):
      number.isFinite
    case .null:
      true
    default:
      false
    }
  }
}
