import Foundation
import HexCore
import Testing

@testable import HexProviders

@Suite("Codex app-server wire connection")
struct CodexAppServerConnectionTests {
  @Test
  func performsExactStableHandshakeBeforeBecomingReady() async throws {
    let channel = TestCodexAppServerChannel()
    let handler = RecordingCodexAppServerNotificationHandler()
    let connection = CodexAppServerConnection(
      configuration: try configuration(),
      channel: channel,
      notificationHandler: handler
    )
    let connecting = Task { try await connection.connect() }

    let initializeFrame = await channel.frame(at: 0)
    let initialize = try decodeFrame(initializeFrame)
    #expect(
      initialize
        == .object([
          "id": .integer(1),
          "method": .string("initialize"),
          "params": .object([
            "clientInfo": .object([
              "name": .string("hex"),
              "title": .string("Hex"),
              "version": .string("0.1.0"),
            ])
          ]),
        ])
    )
    #expect(await channel.frameCount() == 1)

    let response = try encodedLine(
      .object([
        "id": .integer(1),
        "result": initializationResult(),
      ])
    )
    let splitIndex = response.index(response.startIndex, offsetBy: response.count / 2)
    await channel.yield(Data(response[..<splitIndex]))
    await channel.yield(Data(response[splitIndex...]))

    let initializedFrame = await channel.frame(at: 1)
    #expect(
      try decodeFrame(initializedFrame)
        == .object([
          "method": .string("initialized"),
          "params": .object([:]),
        ])
    )
    try await connecting.value

    await connection.disconnect()
    #expect(await channel.closeCount() == 1)
  }

  @Test
  func cancellationDuringOpenStartsAndAwaitsPhysicalClose() async throws {
    let channel = TestCodexAppServerChannel()
    await channel.blockOpen()
    await channel.blockClose()
    let connection = CodexAppServerConnection(
      configuration: try configuration(),
      channel: channel
    )
    let completionProbe = TestTaskCompletionProbe()
    let connecting = Task {
      do {
        try await connection.connect()
        await completionProbe.recordCompletion()
      } catch {
        await completionProbe.recordCompletion()
        throw error
      }
    }
    await channel.waitUntilOpenStarts()

    connecting.cancel()
    try await Task.sleep(for: .milliseconds(20))
    #expect(await channel.hasCloseStarted())
    #expect(!(await completionProbe.hasCompleted()))

    await channel.releaseOpen()
    try await Task.sleep(for: .milliseconds(20))
    #expect(!(await completionProbe.hasCompleted()))
    await channel.releaseClose()
    await #expect(throws: CancellationError.self) {
      try await connecting.value
    }
    #expect(await completionProbe.hasCompleted())
    #expect(await channel.closeCount() == 1)
    #expect(!(await channel.isOpen()))
  }

  @Test
  func cancelledSuspendedOpenMustUnwindBeforeAReplacementCanConnect() async throws {
    let channel = TestCodexAppServerChannel()
    await channel.blockOpen()
    let connection = CodexAppServerConnection(
      configuration: try configuration(),
      channel: channel
    )
    let firstConnect = Task { try await connection.connect() }
    await channel.waitUntilOpenStarts()
    firstConnect.cancel()
    await channel.waitUntilCloseStarts()
    #expect(await channel.closeCount() == 1)

    await #expect(throws: CodexAppServerConnectionError.alreadyConnected) {
      try await connection.connect()
    }

    await channel.releaseOpen()
    await #expect(throws: CancellationError.self) {
      try await firstConnect.value
    }
    #expect(await channel.closeCount() == 1)
    #expect(!(await channel.isOpen()))

    let replacementConnect = Task { try await connection.connect() }
    _ = await channel.frame(at: 0)
    await channel.yield(
      try encodedLine(
        .object([
          "id": .integer(1),
          "result": initializationResult(),
        ])
      )
    )
    _ = await channel.frame(at: 1)
    try await replacementConnect.value
    #expect(await channel.closeCount() == 1)
    #expect(await channel.isOpen())
    await connection.disconnect()
    #expect(await channel.closeCount() == 2)
  }

  @Test
  func cancellationDuringInitializedWriteWinsAndAwaitsPhysicalClose() async throws {
    let channel = TestCodexAppServerChannel()
    let connection = CodexAppServerConnection(
      configuration: try configuration(),
      channel: channel
    )
    await channel.blockClose()
    let completionProbe = TestTaskCompletionProbe()
    let connecting = Task {
      do {
        try await connection.connect()
        await completionProbe.recordCompletion()
      } catch {
        await completionProbe.recordCompletion()
        throw error
      }
    }
    _ = await channel.frame(at: 0)
    await channel.blockNextWrite(failing: true)
    await channel.yield(
      try encodedLine(
        .object([
          "id": .integer(1),
          "result": initializationResult(),
        ])
      )
    )
    let initialized = try decodeFrame(await channel.waitUntilWriteBlocks())
    guard case .object(let initializedObject) = initialized else {
      Issue.record("Expected the initialized notification.")
      await channel.releaseBlockedWrite()
      await channel.releaseClose()
      return
    }
    #expect(initializedObject["method"] == .string("initialized"))

    connecting.cancel()
    try await Task.sleep(for: .milliseconds(20))
    #expect(await channel.hasCloseStarted())
    #expect(!(await completionProbe.hasCompleted()))

    await channel.releaseBlockedWrite()
    try await Task.sleep(for: .milliseconds(20))
    #expect(!(await completionProbe.hasCompleted()))
    await channel.releaseClose()
    await #expect(throws: CancellationError.self) {
      try await connecting.value
    }
    #expect(await completionProbe.hasCompleted())
    #expect(await channel.closeCount() == 1)
    #expect(!(await channel.isOpen()))
  }

  @Test
  func carriesAccountRequestsWithoutExposingTokens() async throws {
    let channel = TestCodexAppServerChannel()
    let connection = CodexAppServerConnection(
      configuration: try configuration(),
      channel: channel
    )
    try await finishHandshake(connection: connection, channel: channel)
    let accountClient = CodexAccountClient(transport: connection)
    let accountRead = Task { try await accountClient.readAccount() }

    let frame = await channel.frame(at: 2)
    #expect(
      try decodeFrame(frame)
        == .object([
          "id": .integer(2),
          "method": .string("account/read"),
          "params": .object(["refreshToken": .boolean(false)]),
        ])
    )
    #expect(!String(decoding: frame, as: UTF8.self).contains("accessToken"))
    await channel.yield(
      try encodedLine(
        .object([
          "id": .integer(2),
          "result": .object([
            "account": .object([
              "type": .string("chatgpt"),
              "email": .null,
              "planType": .string("plus"),
            ]),
            "requiresOpenaiAuth": .boolean(false),
          ]),
        ])
      )
    )

    let snapshot = try await accountRead.value
    #expect(
      snapshot
        == CodexAccountSnapshot(
          account: .chatGPT(email: nil, plan: try CodexAccountPlan(rawValue: "plus")),
          requiresOpenAIAuthentication: false
        )
    )
    await connection.disconnect()
  }

  @Test
  func routesLoginCompletionThroughAnInstalledAccountHandler() async throws {
    let channel = TestCodexAppServerChannel()
    let connection = CodexAppServerConnection(
      configuration: try configuration(),
      channel: channel
    )
    let accountClient = CodexAccountClient(transport: connection)
    let notificationHandler = AcknowledgingCodexAccountNotificationHandler(
      accountClient: accountClient
    )
    try await connection.installNotificationHandler(notificationHandler)
    try await finishHandshake(connection: connection, channel: channel)

    let start = Task { try await accountClient.startLogin(.browser) }
    _ = await channel.frame(at: 2)
    await channel.yield(
      try encodedLine(
        .object([
          "id": .integer(2),
          "result": .object([
            "type": .string("chatgpt"),
            "loginId": .string("login-wire"),
            "authUrl": .string("https://auth.openai.com/authorize"),
          ]),
        ])
      )
    )
    _ = try await start.value

    await channel.yield(
      try encodedLine(
        .object([
          "method": .string("account/login/completed"),
          "params": .object([
            "loginId": .string("login-wire"),
            "success": .boolean(true),
          ]),
        ])
      )
    )
    await notificationHandler.waitUntilHandled()

    let logout = Task { try await accountClient.logout() }
    _ = await channel.frame(at: 3)
    await channel.yield(
      try encodedLine(
        .object([
          "id": .integer(3),
          "result": .object([:]),
        ])
      )
    )
    try await logout.value
    await connection.disconnect()
  }

  @Test
  func correlatesConcurrentResponsesByIdentifier() async throws {
    let channel = TestCodexAppServerChannel()
    let connection = CodexAppServerConnection(
      configuration: try configuration(),
      channel: channel
    )
    try await finishHandshake(connection: connection, channel: channel)

    let first = Task {
      try await connection.send(
        CodexAppServerRequest(method: "account/read", parameters: .object([:]))
      )
    }
    let second = Task {
      try await connection.send(
        CodexAppServerRequest(method: "account/usage/read", parameters: .object([:]))
      )
    }
    let frames = [
      try decodeFrame(await channel.frame(at: 2)),
      try decodeFrame(await channel.frame(at: 3)),
    ]
    let accountReadID = try requestID(for: "account/read", in: frames)
    let usageReadID = try requestID(for: "account/usage/read", in: frames)
    #expect(accountReadID != usageReadID)

    await channel.yield(
      try encodedLine(.object(["id": .integer(usageReadID), "result": .string("second")]))
    )
    await channel.yield(
      try encodedLine(.object(["id": .integer(accountReadID), "result": .string("first")]))
    )
    #expect(try await first.value == .string("first"))
    #expect(try await second.value == .string("second"))
    await connection.disconnect()
  }

  @Test
  func writeFailureAfterMatchingResponseClosesBeforeRequestCompletion() async throws {
    let channel = TestCodexAppServerChannel()
    let connection = CodexAppServerConnection(
      configuration: try configuration(),
      channel: channel
    )
    try await finishHandshake(connection: connection, channel: channel)
    await channel.blockNextWrite(failing: true)
    let completionProbe = TestTaskCompletionProbe()

    let request = Task {
      do {
        let value = try await connection.send(
          CodexAppServerRequest(method: "account/read", parameters: .object([:]))
        )
        await completionProbe.recordCompletion()
        return value
      } catch {
        await completionProbe.recordCompletion()
        throw error
      }
    }
    let frame = try decodeFrame(await channel.waitUntilWriteBlocks())
    guard case .object(let object) = frame, case .integer(let requestID)? = object["id"] else {
      Issue.record("Expected a request identifier.")
      await channel.releaseBlockedWrite()
      await connection.disconnect()
      return
    }
    await channel.yield(
      try encodedLine(.object(["id": .integer(requestID), "result": .object([:])]))
    )
    try await Task.sleep(for: .milliseconds(20))
    #expect(!(await completionProbe.hasCompleted()))

    await channel.blockClose()
    await channel.releaseBlockedWrite()
    await channel.waitUntilCloseStarts()
    try await Task.sleep(for: .milliseconds(20))
    #expect(!(await completionProbe.hasCompleted()))
    #expect(await channel.closeCount() == 0)
    await channel.releaseClose()
    await #expect(throws: CodexAppServerConnectionError.self) {
      try await request.value
    }
    #expect(await completionProbe.hasCompleted())
    #expect(await channel.closeCount() == 1)
  }

  @Test
  func cancellationWinsAConcurrentResponseAndWriteFailureAfterPhysicalClose() async throws {
    let channel = TestCodexAppServerChannel()
    let connection = CodexAppServerConnection(
      configuration: try configuration(),
      channel: channel
    )
    try await finishHandshake(connection: connection, channel: channel)
    await channel.blockNextWrite(failing: true)
    await channel.blockClose()
    let completionProbe = TestTaskCompletionProbe()
    let request = Task {
      do {
        let value = try await connection.send(
          CodexAppServerRequest(method: "account/read", parameters: .object([:]))
        )
        await completionProbe.recordCompletion()
        return value
      } catch {
        await completionProbe.recordCompletion()
        throw error
      }
    }
    let frame = try decodeFrame(await channel.waitUntilWriteBlocks())
    guard case .object(let object) = frame, case .integer(let requestID)? = object["id"] else {
      Issue.record("Expected a request identifier.")
      await channel.releaseBlockedWrite()
      await channel.releaseClose()
      return
    }
    await channel.yield(
      try encodedLine(.object(["id": .integer(requestID), "result": .object([:])]))
    )

    request.cancel()
    await channel.waitUntilCloseStarts()
    await channel.releaseBlockedWrite()
    try await Task.sleep(for: .milliseconds(20))
    #expect(!(await completionProbe.hasCompleted()))
    await channel.releaseClose()

    await #expect(throws: CancellationError.self) {
      try await request.value
    }
    #expect(await completionProbe.hasCompleted())
    #expect(await channel.closeCount() == 1)
    #expect(!(await channel.isOpen()))
  }

  @Test
  func matchingResponseWaitsForSuccessfulWriteCompletion() async throws {
    let channel = TestCodexAppServerChannel()
    let connection = CodexAppServerConnection(
      configuration: try configuration(),
      channel: channel
    )
    try await finishHandshake(connection: connection, channel: channel)
    await channel.blockNextWrite()
    let completionProbe = TestTaskCompletionProbe()

    let request = Task {
      let value = try await connection.send(
        CodexAppServerRequest(method: "account/read", parameters: .object([:]))
      )
      await completionProbe.recordCompletion()
      return value
    }
    let frame = try decodeFrame(await channel.waitUntilWriteBlocks())
    guard case .object(let object) = frame, case .integer(let requestID)? = object["id"] else {
      Issue.record("Expected a request identifier.")
      await channel.releaseBlockedWrite()
      await connection.disconnect()
      return
    }
    await channel.yield(
      try encodedLine(.object(["id": .integer(requestID), "result": .object([:])]))
    )
    try await Task.sleep(for: .milliseconds(20))
    #expect(!(await completionProbe.hasCompleted()))

    await channel.releaseBlockedWrite()
    #expect(try await request.value == .object([:]))
    #expect(await completionProbe.hasCompleted())
    #expect(await channel.closeCount() == 0)
    await connection.disconnect()
  }

  @Test
  func acceptsMultipleBoundedMessagesInOneLargerReadChunk() async throws {
    let channel = TestCodexAppServerChannel()
    let connection = CodexAppServerConnection(
      configuration: try configuration(maximumMessageBytes: 1_024),
      channel: channel
    )
    try await finishHandshake(connection: connection, channel: channel)

    let first = Task {
      try await connection.send(
        CodexAppServerRequest(method: "account/read", parameters: .object([:]))
      )
    }
    let second = Task {
      try await connection.send(
        CodexAppServerRequest(method: "account/usage/read", parameters: .object([:]))
      )
    }
    let frames = [
      try decodeFrame(await channel.frame(at: 2)),
      try decodeFrame(await channel.frame(at: 3)),
    ]
    let firstID = try requestID(for: "account/read", in: frames)
    let secondID = try requestID(for: "account/usage/read", in: frames)
    let firstValue = String(repeating: "a", count: 700)
    let secondValue = String(repeating: "b", count: 700)
    let firstLine = try encodedLine(
      .object(["id": .integer(firstID), "result": .string(firstValue)])
    )
    let secondLine = try encodedLine(
      .object(["id": .integer(secondID), "result": .string(secondValue)])
    )
    var combined = firstLine
    combined.append(secondLine)
    #expect(firstLine.count <= 1_024)
    #expect(secondLine.count <= 1_024)
    #expect(combined.count > 1_024)

    await channel.yield(combined)

    #expect(try await first.value == .string(firstValue))
    #expect(try await second.value == .string(secondValue))
    await connection.disconnect()
  }

  @Test
  func staleNotificationChunkCannotCloseAReplacementConnection() async throws {
    let channel = TestCodexAppServerChannel()
    let handler = GatedCodexAppServerNotificationHandler()
    let connection = CodexAppServerConnection(
      configuration: try configuration(),
      channel: channel,
      notificationHandler: handler
    )
    try await finishHandshake(connection: connection, channel: channel)

    var staleChunk = try encodedLine(
      .object([
        "method": .string("account/updated"),
        "params": .object([:]),
      ])
    )
    staleChunk.append(
      try encodedLine(
        .object([
          "method": .string("account/updated"),
          "params": .object([:]),
        ])
      )
    )
    await channel.yield(staleChunk)
    await handler.waitUntilStarted()

    await connection.disconnect()
    let reconnecting = Task { try await connection.connect() }
    _ = await channel.frame(at: 2)
    await channel.yield(
      try encodedLine(
        .object([
          "id": .integer(1),
          "result": initializationResult(),
        ])
      )
    )
    _ = await channel.frame(at: 3)
    try await reconnecting.value

    await handler.release()
    try await Task.sleep(for: .milliseconds(20))

    #expect(await channel.closeCount() == 1)
    await connection.disconnect()
  }

  @Test
  func rejectsDuplicateMembersUnknownResponsesAndWireHeaders() async throws {
    let hostileLines = [
      Data("{\"id\":2,\"id\":2,\"result\":{}}\n".utf8),
      try encodedLine(.object(["id": .integer(999), "result": .object([:])])),
      try encodedLine(
        .object([
          "jsonrpc": .string("2.0"),
          "id": .integer(2),
          "result": .object([:]),
        ])
      ),
    ]

    for hostileLine in hostileLines {
      let channel = TestCodexAppServerChannel()
      let connection = CodexAppServerConnection(
        configuration: try configuration(),
        channel: channel
      )
      try await finishHandshake(connection: connection, channel: channel)
      let request = Task {
        try await connection.send(
          CodexAppServerRequest(method: "account/read", parameters: .object([:]))
        )
      }
      _ = await channel.frame(at: 2)
      await channel.yield(hostileLine)
      await #expect(throws: CodexAppServerConnectionError.self) {
        try await request.value
      }
      #expect(await channel.closeCount() == 1)
    }
  }

  @Test
  func redactsRemoteTransportAndHandlerFailures() async throws {
    let remoteChannel = TestCodexAppServerChannel()
    let remoteConnection = CodexAppServerConnection(
      configuration: try configuration(),
      channel: remoteChannel
    )
    try await finishHandshake(connection: remoteConnection, channel: remoteChannel)
    let remoteRequest = Task {
      try await remoteConnection.send(
        CodexAppServerRequest(method: "account/read", parameters: .object([:]))
      )
    }
    _ = await remoteChannel.frame(at: 2)
    await remoteChannel.yield(
      try encodedLine(
        .object([
          "id": .integer(2),
          "error": .object([
            "code": .integer(-32_000),
            "message": .string("remote-secret"),
          ]),
        ])
      )
    )
    do {
      _ = try await remoteRequest.value
      Issue.record("Expected remote rejection.")
    } catch let error as CodexAppServerConnectionError {
      #expect(error == .remoteError(code: -32_000))
      #expect(!error.localizedDescription.contains("remote-secret"))
    }
    await remoteConnection.disconnect()

    let handler = RecordingCodexAppServerNotificationHandler()
    await handler.setShouldFail(true)
    let handlerChannel = TestCodexAppServerChannel()
    let handlerConnection = CodexAppServerConnection(
      configuration: try configuration(),
      channel: handlerChannel,
      notificationHandler: handler
    )
    try await finishHandshake(connection: handlerConnection, channel: handlerChannel)
    await handlerChannel.yield(
      try encodedLine(
        .object([
          "method": .string("account/updated"),
          "params": .object([:]),
        ])
      )
    )
    await handlerChannel.waitUntilCloseStarts()
    let followUp = Task {
      try await handlerConnection.send(
        CodexAppServerRequest(method: "account/read", parameters: .object([:]))
      )
    }
    await #expect(throws: CodexAppServerConnectionError.connectionClosed) {
      try await followUp.value
    }
    #expect(await handlerChannel.closeCount() == 1)
  }

  @Test
  func respondsToUnsupportedServerRequestsWithoutExecutingThem() async throws {
    let channel = TestCodexAppServerChannel()
    let connection = CodexAppServerConnection(
      configuration: try configuration(),
      channel: channel
    )
    try await finishHandshake(connection: connection, channel: channel)

    await channel.yield(
      try encodedLine(
        .object([
          "id": .string("approval-1"),
          "method": .string("commandExecution/requestApproval"),
          "params": .object(["secret": .string("never-run")]),
        ])
      )
    )
    let response = try decodeFrame(await channel.frame(at: 2))
    #expect(
      response
        == .object([
          "id": .string("approval-1"),
          "error": .object([
            "code": .integer(-32_601),
            "message": .string("Method not supported by this client."),
          ]),
        ])
    )
    await connection.disconnect()
  }

  @Test
  func rejectsEveryPresentNonStringMethodInsteadOfTreatingItAsAResponse() async throws {
    let invalidMethods: [JSONValue] = [
      .null,
      .boolean(false),
      .integer(7),
      .number(1.5),
      .array([]),
      .object([:]),
    ]

    for invalidMethod in invalidMethods {
      let channel = TestCodexAppServerChannel()
      let connection = CodexAppServerConnection(
        configuration: try configuration(),
        channel: channel
      )
      try await finishHandshake(connection: connection, channel: channel)
      let request = Task {
        try await connection.send(
          CodexAppServerRequest(method: "account/read", parameters: .object([:]))
        )
      }
      let frame = try decodeFrame(await channel.frame(at: 2))
      guard case .object(let object) = frame, let requestID = object["id"] else {
        Issue.record("Expected a request identifier.")
        await connection.disconnect()
        continue
      }
      await channel.yield(
        try encodedLine(
          .object([
            "id": requestID,
            "method": invalidMethod,
            "result": .object([:]),
          ])
        )
      )
      await #expect(throws: CodexAppServerConnectionError.self) {
        try await request.value
      }
      #expect(await channel.closeCount() == 1)
    }
  }

  @Test
  func echoesOpaqueBoundedServerRequestIdentifiersWithoutConversion() async throws {
    let channel = TestCodexAppServerChannel()
    let connection = CodexAppServerConnection(
      configuration: try configuration(),
      channel: channel
    )
    try await finishHandshake(connection: connection, channel: channel)
    let identifiers: [JSONValue] = [
      .integer(Int64.min),
      .integer(-1),
      .integer(Int64.max),
      .string(""),
      .string(String(repeating: "opaque-", count: 1_024)),
      .string("control-\u{0000}-bidi-\u{202E}"),
    ]

    for (offset, identifier) in identifiers.enumerated() {
      await channel.yield(
        try encodedLine(
          .object([
            "id": identifier,
            "method": .string("commandExecution/requestApproval"),
            "params": .object([:]),
          ])
        )
      )
      let response = try decodeFrame(await channel.frame(at: offset + 2))
      guard case .object(let responseObject) = response,
        case .object(let errorObject)? = responseObject["error"]
      else {
        Issue.record("Expected a method-not-found response.")
        continue
      }
      #expect(responseObject["id"] == identifier)
      #expect(errorObject["code"] == .integer(-32_601))
    }
    #expect(await channel.closeCount() == 0)
    await connection.disconnect()
  }

  @Test
  func closesThePhysicalChannelOnCancellationAndTimeout() async throws {
    let cancellationChannel = TestCodexAppServerChannel()
    let cancellationConnection = CodexAppServerConnection(
      configuration: try configuration(),
      channel: cancellationChannel
    )
    try await finishHandshake(
      connection: cancellationConnection,
      channel: cancellationChannel
    )
    let cancelled = Task {
      try await cancellationConnection.send(
        CodexAppServerRequest(method: "account/read", parameters: .object([:]))
      )
    }
    _ = await cancellationChannel.frame(at: 2)
    cancelled.cancel()
    await #expect(throws: CancellationError.self) {
      try await cancelled.value
    }
    #expect(await cancellationChannel.closeCount() == 1)

    let timeoutChannel = TestCodexAppServerChannel()
    let timeoutConnection = CodexAppServerConnection(
      configuration: try configuration(requestTimeoutMilliseconds: 200),
      channel: timeoutChannel
    )
    try await finishHandshake(connection: timeoutConnection, channel: timeoutChannel)
    let timedOut = Task {
      try await timeoutConnection.send(
        CodexAppServerRequest(method: "account/read", parameters: .object([:]))
      )
    }
    _ = await timeoutChannel.frame(at: 2)
    await #expect(throws: CodexAppServerConnectionError.requestTimedOut) {
      try await timedOut.value
    }
    #expect(await timeoutChannel.closeCount() == 1)
  }

  @Test
  func withholdsCancellationAndTimeoutUntilPhysicalCloseCompletes() async throws {
    let cancellationChannel = TestCodexAppServerChannel()
    let cancellationConnection = CodexAppServerConnection(
      configuration: try configuration(),
      channel: cancellationChannel
    )
    try await finishHandshake(
      connection: cancellationConnection,
      channel: cancellationChannel
    )
    await cancellationChannel.blockClose()
    let cancellationProbe = TestTaskCompletionProbe()
    let cancelled = Task {
      do {
        let value = try await cancellationConnection.send(
          CodexAppServerRequest(method: "account/read", parameters: .object([:]))
        )
        await cancellationProbe.recordCompletion()
        return value
      } catch {
        await cancellationProbe.recordCompletion()
        throw error
      }
    }
    _ = await cancellationChannel.frame(at: 2)
    cancelled.cancel()
    await cancellationChannel.waitUntilCloseStarts()
    try await Task.sleep(for: .milliseconds(20))
    #expect(!(await cancellationProbe.hasCompleted()))
    await cancellationChannel.releaseClose()
    await #expect(throws: CancellationError.self) {
      try await cancelled.value
    }
    #expect(await cancellationProbe.hasCompleted())

    let timeoutChannel = TestCodexAppServerChannel()
    let timeoutConnection = CodexAppServerConnection(
      configuration: try configuration(requestTimeoutMilliseconds: 50),
      channel: timeoutChannel
    )
    try await finishHandshake(connection: timeoutConnection, channel: timeoutChannel)
    await timeoutChannel.blockClose()
    let timeoutProbe = TestTaskCompletionProbe()
    let timedOut = Task {
      do {
        let value = try await timeoutConnection.send(
          CodexAppServerRequest(method: "account/read", parameters: .object([:]))
        )
        await timeoutProbe.recordCompletion()
        return value
      } catch {
        await timeoutProbe.recordCompletion()
        throw error
      }
    }
    _ = await timeoutChannel.frame(at: 2)
    await timeoutChannel.waitUntilCloseStarts()
    try await Task.sleep(for: .milliseconds(20))
    #expect(!(await timeoutProbe.hasCompleted()))
    await timeoutChannel.releaseClose()
    await #expect(throws: CodexAppServerConnectionError.requestTimedOut) {
      try await timedOut.value
    }
    #expect(await timeoutProbe.hasCompleted())
  }

  @Test
  func rejectsInvalidConfigurationAndOversizedFrames() async throws {
    #expect(throws: CodexAppServerConnectionError.invalidConfiguration) {
      try CodexAppServerConnectionConfiguration(
        clientName: "hex\nspoof",
        clientVersion: "0.1.0"
      )
    }
    #expect(throws: CodexAppServerConnectionError.invalidConfiguration) {
      try CodexAppServerConnectionConfiguration(
        clientVersion: "0.1.0",
        maximumMessageBytes: 32
      )
    }

    let channel = TestCodexAppServerChannel()
    let connection = CodexAppServerConnection(
      configuration: try configuration(maximumMessageBytes: 1_024),
      channel: channel
    )
    try await finishHandshake(connection: connection, channel: channel)
    await channel.yield(Data(repeating: 0x61, count: 1_025))

    let request = Task {
      try await connection.send(
        CodexAppServerRequest(method: "account/read", parameters: .object([:]))
      )
    }
    await #expect(throws: CodexAppServerConnectionError.connectionClosed) {
      try await request.value
    }
    #expect(await channel.closeCount() == 1)
  }

  @Test
  func rejectsUnboundedOutgoingValuesWithoutClosingTheConnection() async throws {
    let channel = TestCodexAppServerChannel()
    let connection = CodexAppServerConnection(
      configuration: try configuration(maximumMessageBytes: 1_024),
      channel: channel
    )
    try await finishHandshake(connection: connection, channel: channel)

    await #expect(throws: CodexAppServerConnectionError.limitExceeded) {
      try await connection.send(
        CodexAppServerRequest(
          method: "account/read",
          parameters: .object(["oversized": .string(String(repeating: "x", count: 2_000))])
        )
      )
    }
    #expect(await channel.closeCount() == 0)

    let valid = Task {
      try await connection.send(
        CodexAppServerRequest(method: "account/read", parameters: .object([:]))
      )
    }
    let frame = try decodeFrame(await channel.frame(at: 2))
    guard case .object(let object) = frame, case .integer(let requestID)? = object["id"] else {
      Issue.record("Expected a bounded follow-up request.")
      await connection.disconnect()
      return
    }
    await channel.yield(
      try encodedLine(.object(["id": .integer(requestID), "result": .object([:])]))
    )
    #expect(try await valid.value == .object([:]))
    await connection.disconnect()
  }

  private func configuration(
    maximumMessageBytes: Int = 1_048_576,
    requestTimeoutMilliseconds: UInt64 = 30_000
  ) throws -> CodexAppServerConnectionConfiguration {
    try CodexAppServerConnectionConfiguration(
      clientVersion: "0.1.0",
      maximumMessageBytes: maximumMessageBytes,
      requestTimeoutMilliseconds: requestTimeoutMilliseconds
    )
  }

  private func finishHandshake(
    connection: CodexAppServerConnection,
    channel: TestCodexAppServerChannel
  ) async throws {
    let connecting = Task { try await connection.connect() }
    _ = await channel.frame(at: 0)
    await channel.yield(
      try encodedLine(
        .object([
          "id": .integer(1),
          "result": initializationResult(),
        ])
      )
    )
    _ = await channel.frame(at: 1)
    try await connecting.value
  }

  private func initializationResult() -> JSONValue {
    .object([
      "codexHome": .string("/Users/person/.codex"),
      "platformFamily": .string("unix"),
      "platformOs": .string("macos"),
      "userAgent": .string("codex-cli/0.151.0"),
    ])
  }

  private func encodedLine(_ value: JSONValue) throws -> Data {
    var data = try JSONEncoder().encode(value)
    data.append(0x0A)
    return data
  }

  private func decodeFrame(_ frame: Data) throws -> JSONValue {
    var line = frame
    if line.last == 0x0A {
      line.removeLast()
    }
    return try JSONDecoder().decode(JSONValue.self, from: line)
  }

  private func requestID(for method: String, in values: [JSONValue]) throws -> Int64 {
    for value in values {
      guard case .object(let object) = value else { continue }
      if object["method"] == .string(method), case .integer(let identifier)? = object["id"] {
        return identifier
      }
    }
    throw CodexAppServerConnectionError.protocolViolation
  }
}
