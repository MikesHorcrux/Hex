import Foundation
import HexCore
import Testing

@testable import HexProviders

@Suite("Codex account bridge")
struct CodexAccountClientTests {
  @Test
  func readsNonSecretChatGPTAccountMetadata() async throws {
    let transport = TestCodexAppServerTransport(
      outcomes: [
        .value(
          .object([
            "account": .object([
              "type": .string("chatgpt"),
              "email": .string("person@example.com"),
              "planType": .string("plus"),
            ]),
            "requiresOpenaiAuth": .boolean(false),
          ])
        )
      ]
    )
    let client = CodexAccountClient(transport: transport)

    let snapshot = try await client.readAccount(refreshToken: true)

    #expect(
      snapshot
        == CodexAccountSnapshot(
          account: .chatGPT(
            email: "person@example.com",
            plan: try CodexAccountPlan(rawValue: "plus")
          ),
          requiresOpenAIAuthentication: false
        )
    )
    #expect(
      await transport.requests()
        == [
          CodexAppServerRequest(
            method: "account/read",
            parameters: .object(["refreshToken": .boolean(true)])
          )
        ]
    )
  }

  @Test
  func readsSignedOutAndSupportedNonChatGPTAccounts() async throws {
    let transport = TestCodexAppServerTransport(
      outcomes: [
        .value(
          .object([
            "account": .null,
            "requiresOpenaiAuth": .boolean(true),
          ])
        ),
        .value(
          .object([
            "account": .object(["type": .string("apiKey")]),
            "requiresOpenaiAuth": .boolean(false),
          ])
        ),
        .value(
          .object([
            "account": .object([
              "type": .string("amazonBedrock"),
              "usesCodexManagedCredentials": .boolean(true),
            ]),
            "requiresOpenaiAuth": .boolean(false),
          ])
        ),
      ]
    )
    let client = CodexAccountClient(transport: transport)

    #expect(
      try await client.readAccount()
        == CodexAccountSnapshot(account: nil, requiresOpenAIAuthentication: true)
    )
    #expect(
      try await client.readAccount()
        == CodexAccountSnapshot(account: .apiKey, requiresOpenAIAuthentication: false)
    )
    #expect(
      try await client.readAccount()
        == CodexAccountSnapshot(
          account: .amazonBedrock(usesCodexManagedCredentials: true),
          requiresOpenAIAuthentication: false
        )
    )
  }

  @Test
  func startsBrowserLoginWithoutReceivingCredentials() async throws {
    let transport = TestCodexAppServerTransport(
      outcomes: [
        .value(
          .object([
            "type": .string("chatgpt"),
            "loginId": .string("login-123"),
            "authUrl": .string("https://auth.openai.com/authorize?client=codex"),
          ])
        )
      ]
    )
    let client = CodexAccountClient(transport: transport)

    let challenge = try await client.startLogin(.browser)

    #expect(
      challenge
        == .browser(
          loginID: try CodexLoginID(rawValue: "login-123"),
          authorizationURL: try #require(
            URL(string: "https://auth.openai.com/authorize?client=codex")
          )
        )
    )
    let requests = await transport.requests()
    #expect(
      requests
        == [
          CodexAppServerRequest(
            method: "account/login/start",
            parameters: .object(["type": .string("chatgpt")])
          )
        ]
    )
    #expect(!String(describing: requests).contains("accessToken"))
    #expect(!String(describing: requests).contains("apiKey"))
  }

  @Test
  func startsDeviceCodeLoginWithExactProtocolShape() async throws {
    let transport = TestCodexAppServerTransport(
      outcomes: [
        .value(
          .object([
            "type": .string("chatgptDeviceCode"),
            "loginId": .string("device-123"),
            "userCode": .string("ABCD-EFGH"),
            "verificationUrl": .string("https://auth.openai.com/device"),
          ])
        )
      ]
    )
    let client = CodexAccountClient(transport: transport)

    let challenge = try await client.startLogin(.deviceCode)

    #expect(
      challenge
        == .deviceCode(
          loginID: try CodexLoginID(rawValue: "device-123"),
          userCode: "ABCD-EFGH",
          verificationURL: try #require(URL(string: "https://auth.openai.com/device"))
        )
    )
    #expect(
      await transport.requests().first?.parameters
        == .object(["type": .string("chatgptDeviceCode")])
    )
  }

  @Test
  func bindsCancellationToTheIssuedLoginIdentifier() async throws {
    let transport = TestCodexAppServerTransport(
      outcomes: [
        .value(
          .object([
            "type": .string("chatgpt"),
            "loginId": .string("login-expected"),
            "authUrl": .string("https://auth.openai.com/authorize"),
          ])
        ),
        .value(.object(["status": .string("canceled")])),
      ]
    )
    let client = CodexAccountClient(transport: transport)
    let challenge = try await client.startLogin(.browser)

    await #expect(throws: CodexAccountClientError.loginIdentifierMismatch) {
      try await client.cancelLogin(CodexLoginID(rawValue: "login-attacker"))
    }
    #expect(await transport.requests().count == 1)

    let status = try await client.cancelLogin(challenge.loginID)
    #expect(status == .cancelled)
    #expect(
      await transport.requests().last
        == CodexAppServerRequest(
          method: "account/login/cancel",
          parameters: .object(["loginId": .string("login-expected")])
        )
    )
  }

  @Test
  func correlatesAndRedactsLoginCompletionNotifications() async throws {
    let transport = TestCodexAppServerTransport(
      outcomes: [
        .value(
          .object([
            "type": .string("chatgpt"),
            "loginId": .string("login-completion"),
            "authUrl": .string("https://auth.openai.com/authorize"),
          ])
        ),
        .value(.object([:])),
      ]
    )
    let client = CodexAccountClient(transport: transport)
    _ = try await client.startLogin(.browser)
    let completion = try CodexLoginCompletion(
      appServerParameters: .object([
        "loginId": .string("login-completion"),
        "success": .boolean(false),
        "error": .string("server-secret-detail"),
      ])
    )

    try await client.acceptLoginCompletion(completion)
    try await client.logout()

    #expect(!String(describing: completion).contains("server-secret-detail"))
    #expect(await transport.requests().last?.method == "account/logout")
  }

  @Test
  func rejectsMismatchedAndUncorrelatableCompletions() async throws {
    let transport = TestCodexAppServerTransport(
      outcomes: [
        .value(
          .object([
            "type": .string("chatgpt"),
            "loginId": .string("login-real"),
            "authUrl": .string("https://auth.openai.com/authorize"),
          ])
        )
      ]
    )
    let client = CodexAccountClient(transport: transport)
    _ = try await client.startLogin(.browser)

    let mismatch = try CodexLoginCompletion(
      appServerParameters: .object([
        "loginId": .string("login-other"),
        "success": .boolean(true),
      ])
    )
    await #expect(throws: CodexAccountClientError.loginIdentifierMismatch) {
      try await client.acceptLoginCompletion(mismatch)
    }

    let missingID = try CodexLoginCompletion(
      appServerParameters: .object([
        "loginId": .null,
        "success": .boolean(true),
      ])
    )
    await #expect(throws: CodexAccountClientError.loginIdentifierMismatch) {
      try await client.acceptLoginCompletion(missingID)
    }
  }

  @Test
  func rejectsUnsafeOrStructurallyInvalidResponses() async throws {
    let unsafeValues: [JSONValue] = [
      .object([
        "type": .string("chatgpt"),
        "loginId": .string("login\nspoof"),
        "authUrl": .string("https://auth.openai.com/authorize"),
      ]),
      .object([
        "type": .string("chatgpt"),
        "loginId": .string("login-safe"),
        "authUrl": .string("http://auth.openai.com/authorize"),
      ]),
      .object([
        "type": .string("chatgpt"),
        "loginId": .string("login-safe"),
        "authUrl": .string("https://user@attacker.test/authorize"),
      ]),
      .object([
        "type": .string("chatgptDeviceCode"),
        "loginId": .string("login-safe"),
        "userCode": .string("ALLOW\u{202E}DENY"),
        "verificationUrl": .string("https://auth.openai.com/device"),
      ]),
    ]

    for value in unsafeValues {
      let transport = TestCodexAppServerTransport(outcomes: [.value(value)])
      let client = CodexAccountClient(transport: transport)
      let mode: CodexChatGPTLoginMode
      if case .object(let object) = value,
        object["type"] == .string("chatgptDeviceCode")
      {
        mode = .deviceCode
      } else {
        mode = .browser
      }
      await #expect(throws: CodexAccountClientError.malformedResponse) {
        try await client.startLogin(mode)
      }
    }
  }

  @Test
  func rejectsUnknownAccountTypesAndPresentationSpoofing() async throws {
    let values: [JSONValue] = [
      .object([
        "account": .object(["type": .string("future-secret-bearing-account")]),
        "requiresOpenaiAuth": .boolean(false),
      ]),
      .object([
        "account": .object([
          "type": .string("chatgpt"),
          "email": .string("person@example.com\u{200B}"),
          "planType": .string("plus"),
        ]),
        "requiresOpenaiAuth": .boolean(false),
      ]),
      .object([
        "account": .object([
          "type": .string("chatgpt"),
          "email": .null,
          "planType": .string("PLUS"),
        ]),
        "requiresOpenaiAuth": .boolean(false),
      ]),
    ]

    for value in values {
      let client = CodexAccountClient(
        transport: TestCodexAppServerTransport(outcomes: [.value(value)])
      )
      await #expect(throws: CodexAccountClientError.malformedResponse) {
        try await client.readAccount()
      }
    }
  }

  @Test
  func serializesPendingLoginAndLogoutTransitions() async throws {
    let transport = TestCodexAppServerTransport(
      outcomes: [
        .value(
          .object([
            "type": .string("chatgpt"),
            "loginId": .string("login-pending"),
            "authUrl": .string("https://auth.openai.com/authorize"),
          ])
        )
      ]
    )
    let client = CodexAccountClient(transport: transport)
    _ = try await client.startLogin(.browser)

    await #expect(throws: CodexAccountClientError.loginAlreadyPending) {
      try await client.startLogin(.deviceCode)
    }
    await #expect(throws: CodexAccountClientError.loginAlreadyPending) {
      try await client.logout()
    }
    #expect(await transport.requests().count == 1)
  }

  @Test
  func reservesTheTransitionAcrossActorReentrancyAndCancellation() async throws {
    let transport = GatedCodexAppServerTransport()
    let client = CodexAccountClient(transport: transport)
    let firstStart = Task {
      try await client.startLogin(.browser)
    }
    await transport.waitForRequest()

    await #expect(throws: CodexAccountClientError.transitionInProgress) {
      try await client.startLogin(.deviceCode)
    }
    await #expect(throws: CodexAccountClientError.transitionInProgress) {
      try await client.logout()
    }

    firstStart.cancel()
    await transport.succeed(
      with: .object([
        "type": .string("chatgpt"),
        "loginId": .string("cancelled-start"),
        "authUrl": .string("https://auth.openai.com/authorize"),
      ])
    )
    await #expect(throws: CancellationError.self) {
      try await firstStart.value
    }

    let staleCompletion = try CodexLoginCompletion(
      appServerParameters: .object([
        "loginId": .string("cancelled-start"),
        "success": .boolean(true),
      ])
    )
    await #expect(throws: CodexAccountClientError.unexpectedLoginCompletion) {
      try await client.acceptLoginCompletion(staleCompletion)
    }
  }

  @Test
  func redactsTransportFailuresAndPreservesCancellation() async throws {
    let failingClient = CodexAccountClient(
      transport: TestCodexAppServerTransport(outcomes: [.failure])
    )

    do {
      _ = try await failingClient.readAccount()
      Issue.record("Expected transport failure.")
    } catch let error as CodexAccountClientError {
      #expect(error == .transportFailure)
      #expect(!error.localizedDescription.contains("transport-secret"))
    } catch {
      Issue.record("Expected a redacted CodexAccountClientError.")
    }

    let cancelledClient = CodexAccountClient(
      transport: TestCodexAppServerTransport(outcomes: [.cancellation])
    )
    await #expect(throws: CancellationError.self) {
      try await cancelledClient.readAccount()
    }
  }

  @Test
  func requiresExactEmptyLogoutResponse() async throws {
    let transport = TestCodexAppServerTransport(
      outcomes: [.value(.object(["unexpected": .boolean(true)]))]
    )
    let client = CodexAccountClient(transport: transport)

    await #expect(throws: CodexAccountClientError.malformedResponse) {
      try await client.logout()
    }
  }

  @Test
  func rejectsContradictorySuccessfulCompletionErrors() throws {
    #expect(throws: CodexAccountClientError.malformedResponse) {
      try CodexLoginCompletion(
        appServerParameters: .object([
          "loginId": .string("login-contradiction"),
          "success": .boolean(true),
          "error": .string("contradictory-secret"),
        ])
      )
    }
  }
}
