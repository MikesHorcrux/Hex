import Foundation
import HexCore
import Testing

@testable import HexProviders

@Suite("Codex account login-flow regressions")
struct CodexAccountLoginFlowRegressionTests {
  @Test
  func acceptsOneLateCompletionForEachOfMultipleCancelledFlows() async throws {
    let transport = GatedCodexAppServerTransport()
    let client = CodexAccountClient(transport: transport)
    let firstID = try await startAndCancelLogin(
      named: "cancelled-first",
      client: client,
      transport: transport,
      expectedRequestCount: 1
    )
    let secondID = try await startAndCancelLogin(
      named: "cancelled-second",
      client: client,
      transport: transport,
      expectedRequestCount: 3
    )

    let firstCompletion = try completion(for: firstID)
    let secondCompletion = try completion(for: secondID)
    try await client.acceptLoginCompletion(firstCompletion)
    try await client.acceptLoginCompletion(secondCompletion)

    await #expect(throws: CodexAccountClientError.unexpectedLoginCompletion) {
      try await client.acceptLoginCompletion(firstCompletion)
    }
    await #expect(throws: CodexAccountClientError.unexpectedLoginCompletion) {
      try await client.acceptLoginCompletion(secondCompletion)
    }
  }

  @Test
  func rejectsAChallengeThatReusesAnIdentifierFromThePhysicalConnection() async throws {
    let transport = GatedCodexAppServerTransport()
    let client = CodexAccountClient(transport: transport)
    let retiredID = try await startAndCancelLogin(
      named: "reused-login-id",
      client: client,
      transport: transport,
      expectedRequestCount: 1
    )

    let replacement = Task { try await client.startLogin(.browser) }
    await transport.waitForRequest(count: 3)
    let lateRetiredCompletion = try completion(for: retiredID)
    try await client.acceptLoginCompletion(lateRetiredCompletion)
    await transport.succeed(with: challenge(named: retiredID.rawValue))

    await #expect(throws: CodexAccountClientError.loginIdentifierReused) {
      try await replacement.value
    }
    await #expect(throws: CodexAccountClientError.unexpectedLoginCompletion) {
      try await client.acceptLoginCompletion(lateRetiredCompletion)
    }
  }

  @Test
  func permitsOnlyOneUnboundEarlyCompletion() async throws {
    let transport = GatedCodexAppServerTransport()
    let client = CodexAccountClient(transport: transport)
    let starting = Task { try await client.startLogin(.browser) }
    await transport.waitForRequest()
    let firstID = try CodexLoginID(rawValue: "first-early")
    let firstCompletion = try completion(for: firstID)
    let secondCompletion = try completion(
      for: CodexLoginID(rawValue: "second-early")
    )

    try await client.acceptLoginCompletion(firstCompletion)
    await #expect(throws: CodexAccountClientError.unexpectedLoginCompletion) {
      try await client.acceptLoginCompletion(secondCompletion)
    }
    await transport.succeed(with: challenge(named: firstID.rawValue))

    #expect(try await starting.value.loginID == firstID)
    await #expect(throws: CodexAccountClientError.unexpectedLoginCompletion) {
      try await client.acceptLoginCompletion(firstCompletion)
    }
  }

  @Test
  func retainsCancelledFlowsAcrossAwaitingCancellingAndLogoutTransitions() async throws {
    let transport = GatedCodexAppServerTransport()
    let client = CodexAccountClient(transport: transport)
    let firstRetiredID = try await startAndCancelLogin(
      named: "retired-awaiting",
      client: client,
      transport: transport,
      expectedRequestCount: 1
    )
    let secondRetiredID = try await startAndCancelLogin(
      named: "retired-cancelling",
      client: client,
      transport: transport,
      expectedRequestCount: 3
    )

    let activeStart = Task { try await client.startLogin(.browser) }
    await transport.waitForRequest(count: 5)
    await transport.succeed(with: challenge(named: "active-cancelling"))
    let activeID = try await activeStart.value.loginID
    try await client.acceptLoginCompletion(completion(for: firstRetiredID))

    let activeCancellation = Task { try await client.cancelLogin(activeID) }
    await transport.waitForRequest(count: 6)
    try await client.acceptLoginCompletion(completion(for: secondRetiredID))
    try await client.acceptLoginCompletion(completion(for: activeID))
    await transport.succeed(with: .object(["status": .string("canceled")]))
    #expect(try await activeCancellation.value == .cancelled)

    let logoutRetiredID = try await startAndCancelLogin(
      named: "retired-logout",
      client: client,
      transport: transport,
      expectedRequestCount: 7
    )
    let logout = Task { try await client.logout() }
    await transport.waitForRequest(count: 9)
    try await client.acceptLoginCompletion(completion(for: logoutRetiredID))
    await transport.succeed(with: .object([:]))
    try await logout.value
  }

  @Test
  func exhaustsBeforeSendingAndRetiresOnlyAfterPhysicalTeardown() async throws {
    let transport = GatedCodexAppServerTransport()
    let client = try #require(
      CodexAccountClient(
        transport: transport,
        loginFlowHistoryCapacity: 2
      )
    )
    _ = try await startAndCancelLogin(
      named: "capacity-first",
      client: client,
      transport: transport,
      expectedRequestCount: 1
    )
    _ = try await startAndCancelLogin(
      named: "capacity-second",
      client: client,
      transport: transport,
      expectedRequestCount: 3
    )

    await #expect(throws: CodexAccountClientError.loginFlowHistoryExhausted) {
      try await client.startLogin(.browser)
    }
    #expect(await transport.requestCount() == 4)

    await transport.blockGenerationRetirement()
    let completionProbe = TestTaskCompletionProbe()
    let retirement = Task {
      await client.retireLoginFlowGeneration()
      await completionProbe.recordCompletion()
    }
    await transport.waitUntilGenerationRetirementStarts()
    #expect(!(await completionProbe.hasCompleted()))
    retirement.cancel()
    #expect(!(await completionProbe.hasCompleted()))
    await #expect(throws: CodexAccountClientError.transitionInProgress) {
      try await client.startLogin(.browser)
    }

    await transport.releaseGenerationRetirement()
    await retirement.value
    #expect(await completionProbe.hasCompleted())
    #expect(await transport.retirementCount() == 1)
    await #expect(throws: CodexAccountClientError.loginFlowGenerationRetired) {
      try await client.startLogin(.browser)
    }
    await client.retireLoginFlowGeneration()
    #expect(await transport.retirementCount() == 1)

    let freshTransport = GatedCodexAppServerTransport()
    let freshClient = try #require(
      CodexAccountClient(
        transport: freshTransport,
        loginFlowHistoryCapacity: 2
      )
    )
    let freshStart = Task { try await freshClient.startLogin(.browser) }
    await freshTransport.waitForRequest()
    await freshTransport.succeed(with: challenge(named: "capacity-first"))
    #expect(try await freshStart.value.loginID.rawValue == "capacity-first")
  }

  @Test
  func retirementWinsAnInFlightStartAndLeavesTheClientTerminal() async throws {
    let transport = GatedCodexAppServerTransport()
    let client = CodexAccountClient(transport: transport)
    let starting = Task { try await client.startLogin(.browser) }
    await transport.waitForRequest()

    await client.retireLoginFlowGeneration()

    await #expect(throws: CodexAccountClientError.transportFailure) {
      try await starting.value
    }
    await #expect(throws: CodexAccountClientError.loginFlowGenerationRetired) {
      try await client.readAccount()
    }
    await #expect(throws: CodexAccountClientError.loginFlowGenerationRetired) {
      try await client.logout()
    }
  }

  @Test
  func rejectsInvalidTestLedgerCapacities() {
    let transport = GatedCodexAppServerTransport()

    for capacity in [0, 65] {
      switch CodexAccountClient(
        transport: transport,
        loginFlowHistoryCapacity: capacity
      ) {
      case .none:
        break
      case .some:
        Issue.record("Expected an invalid ledger capacity to fail initialization.")
      }
    }
  }

  private func startAndCancelLogin(
    named rawLoginID: String,
    client: CodexAccountClient,
    transport: GatedCodexAppServerTransport,
    expectedRequestCount: Int
  ) async throws -> CodexLoginID {
    let starting = Task { try await client.startLogin(.browser) }
    await transport.waitForRequest(count: expectedRequestCount)
    await transport.succeed(with: challenge(named: rawLoginID))
    let loginID = try await starting.value.loginID

    let cancelling = Task { try await client.cancelLogin(loginID) }
    await transport.waitForRequest(count: expectedRequestCount + 1)
    await transport.succeed(with: .object(["status": .string("canceled")]))
    #expect(try await cancelling.value == .cancelled)
    return loginID
  }

  private func challenge(named loginID: String) -> JSONValue {
    .object([
      "type": .string("chatgpt"),
      "loginId": .string(loginID),
      "authUrl": .string("https://auth.openai.com/authorize"),
    ])
  }

  private func completion(for loginID: CodexLoginID) throws -> CodexLoginCompletion {
    try CodexLoginCompletion(
      appServerParameters: .object([
        "loginId": .string(loginID.rawValue),
        "success": .boolean(false),
        "error": .string("provider detail that must remain redacted"),
      ])
    )
  }
}
