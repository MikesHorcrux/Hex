import Foundation
import HexCore
import Testing

@testable import HexProviders

@Suite("Codex compatibility app-server status provider")
struct CodexAppServerCompatibilityAccountStatusProviderTests {
  @Test
  func closesThePhysicalChannelAfterReadingAccountState() async throws {
    let channel = TestCodexAppServerChannel()
    let provider = CodexAppServerCompatibilityAccountStatusProvider(
      configuration: try CodexAppServerConnectionConfiguration(clientVersion: "0.1.0"),
      channel: channel
    )
    let statusTask = Task { await provider.status() }

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
    let accountRequest = try decodeFrame(await channel.frame(at: 2))
    let requestID = try requestID(in: accountRequest)
    await channel.yield(
      try encodedLine(
        .object([
          "id": .integer(requestID),
          "result": .object([
            "account": .null,
            "requiresOpenaiAuth": .boolean(true),
          ]),
        ])
      )
    )

    #expect(await statusTask.value == .requiresOpenAIAuthentication)
    #expect(await channel.closeCount() == 1)
    #expect(!(await channel.isOpen()))
  }

  @Test
  func completesBrowserLoginWithoutExposingCompletionAndRetiresTheChannel() async throws {
    let channel = TestCodexAppServerChannel()
    let provider = CodexAppServerCompatibilityAccountStatusProvider(
      configuration: try CodexAppServerConnectionConfiguration(clientVersion: "0.1.0"),
      channel: channel
    )
    let startTask = Task { try await provider.startLogin(.browser) }

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
    let startRequest = try decodeFrame(await channel.frame(at: 2))
    let startRequestID = try requestID(in: startRequest)
    await channel.yield(
      try encodedLine(
        .object([
          "id": .integer(startRequestID),
          "result": .object([
            "type": .string("chatgpt"),
            "loginId": .string("browser-login"),
            "authUrl": .string("https://auth.openai.com/authorize"),
          ]),
        ])
      )
    )

    let challenge = try await startTask.value
    #expect(
      challenge
        == .browser(
          loginID: try CodexLoginID(rawValue: "browser-login"),
          authorizationURL: try #require(URL(string: "https://auth.openai.com/authorize"))
        )
    )
    #expect(!String(describing: challenge).contains("accessToken"))

    await channel.yield(
      try encodedLine(
        .object([
          "method": .string("account/login/completed"),
          "params": .object([
            "loginId": .string("browser-login"),
            "success": .boolean(true),
          ]),
        ])
      )
    )
    try await provider.completeLogin(challenge.loginID)

    #expect(await channel.closeCount() == 1)
    #expect(!(await channel.isOpen()))
  }

  @Test
  func cancellationDuringCompletionPollingRetiresTheChannel() async throws {
    let channel = TestCodexAppServerChannel()
    let provider = CodexAppServerCompatibilityAccountStatusProvider(
      configuration: try CodexAppServerConnectionConfiguration(clientVersion: "0.1.0"),
      channel: channel
    )
    let startTask = Task { try await provider.startLogin(.deviceCode) }

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
    let startRequest = try decodeFrame(await channel.frame(at: 2))
    let startRequestID = try requestID(in: startRequest)
    await channel.yield(
      try encodedLine(
        .object([
          "id": .integer(startRequestID),
          "result": .object([
            "type": .string("chatgptDeviceCode"),
            "loginId": .string("device-login"),
            "userCode": .string("ABCD-EFGH"),
            "verificationUrl": .string("https://auth.openai.com/device"),
          ]),
        ])
      )
    )
    let challenge = try await startTask.value

    let completionTask = Task {
      try await provider.completeLogin(challenge.loginID)
    }
    try await Task.sleep(for: .milliseconds(20))
    completionTask.cancel()

    await #expect(throws: CancellationError.self) {
      try await completionTask.value
    }
    #expect(await channel.closeCount() == 1)
    #expect(!(await channel.isOpen()))
  }

  private func initializationResult() -> JSONValue {
    .object([
      "codexHome": .string("/Users/test/.codex"),
      "platformFamily": .string("unix"),
      "platformOs": .string("macos"),
      "userAgent": .string("codex-cli/test"),
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

  private func requestID(in value: JSONValue) throws -> Int64 {
    guard case .object(let object) = value,
      case .integer(let requestID)? = object["id"]
    else {
      throw TestError.invalidRequest
    }
    return requestID
  }

  private enum TestError: Error, Sendable {
    case invalidRequest
  }
}
