import Foundation
import HexCore
import Testing

@testable import HexProviders

@Suite("Codex account login-flow regressions")
struct CodexAccountLoginFlowRegressionTests {
  @Test
  func crossFacadeStartAwaitCancelAndLogoutShareTheGenerationTransition() async throws {
    let transport = GatedCodexAppServerTransport()
    let startingClient = CodexAccountClient(transport: transport)
    let logoutClient = CodexAccountClient(transport: transport)
    let cancellingClient = CodexAccountClient(transport: transport)

    let starting = Task { try await startingClient.startLogin(.browser) }
    await transport.waitForRequest()

    let logoutDuringStart = Task { try await logoutClient.logout() }
    try await Task.sleep(for: .milliseconds(20))
    if await transport.recordedRequests().last?.method == "account/logout" {
      await transport.succeed(with: .object([:]))
    }
    await #expect(throws: CodexAccountClientError.transitionInProgress) {
      try await logoutDuringStart.value
    }
    #expect(await transport.requestCount() == 1)

    await transport.succeed(with: challenge(named: "cross-facade-active"))
    let loginID = try await starting.value.loginID

    let logoutDuringAwait = Task { try await logoutClient.logout() }
    try await Task.sleep(for: .milliseconds(20))
    if await transport.recordedRequests().last?.method == "account/logout" {
      await transport.succeed(with: .object([:]))
    }
    await #expect(throws: CodexAccountClientError.loginAlreadyPending) {
      try await logoutDuringAwait.value
    }
    #expect(await transport.requestCount() == 1)

    let cancelling = Task { try await cancellingClient.cancelLogin(loginID) }
    await transport.waitForRequest(count: 2)
    let logoutDuringCancellation = Task { try await logoutClient.logout() }
    try await Task.sleep(for: .milliseconds(20))
    if await transport.recordedRequests().last?.method == "account/logout" {
      await transport.succeed(with: .object([:]))
    }
    await #expect(throws: CodexAccountClientError.transitionInProgress) {
      try await logoutDuringCancellation.value
    }

    await transport.succeed(with: .object(["status": .string("canceled")]))
    #expect(try await cancelling.value == .cancelled)
    await transport.enqueueResponse(.object([:]))
    try await logoutClient.logout()
  }

  @Test
  func logoutReservationBlocksStartCancelAndLogoutOnOtherFacades() async throws {
    let transport = GatedCodexAppServerTransport()
    let setupClient = CodexAccountClient(transport: transport)
    let logoutClient = CodexAccountClient(transport: transport)
    let startingClient = CodexAccountClient(transport: transport)
    let cancellingClient = CodexAccountClient(transport: transport)
    let secondLogoutClient = CodexAccountClient(transport: transport)

    let retiredID = try await startAndCancelLogin(
      named: "stale-before-logout",
      client: setupClient,
      transport: transport,
      expectedRequestCount: 1
    )
    let logout = Task { try await logoutClient.logout() }
    await transport.waitForRequest(count: 3)

    let starting = Task { try await startingClient.startLogin(.browser) }
    let cancelling = Task { try await cancellingClient.cancelLogin(retiredID) }
    let secondLogout = Task { try await secondLogoutClient.logout() }
    try await Task.sleep(for: .milliseconds(20))

    let requests = await transport.recordedRequests()
    #expect(
      requests.map(\.method)
        == [
          "account/login/start",
          "account/login/cancel",
          "account/logout",
        ]
    )
    await transport.succeed(with: .object([:]))
    try await logout.value

    for request in requests.dropFirst(3) {
      switch request.method {
      case "account/login/start":
        await transport.succeed(with: challenge(named: "unexpected-start"))
      case "account/logout":
        await transport.succeed(with: .object([:]))
      default:
        break
      }
    }

    await #expect(throws: CodexAccountClientError.transitionInProgress) {
      try await starting.value
    }
    await #expect(throws: CodexAccountClientError.transitionInProgress) {
      try await cancelling.value
    }
    await #expect(throws: CodexAccountClientError.transitionInProgress) {
      try await secondLogout.value
    }
  }

  @Test
  func thirdFacadeCanAcceptCompletionAndCancelTheSharedActiveFlow() async throws {
    let transport = GatedCodexAppServerTransport()
    let startingClient = CodexAccountClient(transport: transport)
    let completionClient = CodexAccountClient(transport: transport)
    let cancellingClient = CodexAccountClient(transport: transport)

    let starting = Task { try await startingClient.startLogin(.browser) }
    await transport.waitForRequest()
    await transport.succeed(with: challenge(named: "third-facade-active"))
    let loginID = try await starting.value.loginID

    let cancelling = Task { try await cancellingClient.cancelLogin(loginID) }
    try await Task.sleep(for: .milliseconds(20))
    let requests = await transport.recordedRequests()
    #expect(requests.last?.method == "account/login/cancel")
    guard requests.last?.method == "account/login/cancel" else {
      _ = try? await cancelling.value
      return
    }

    let completion = try completion(for: loginID)
    try await completionClient.acceptLoginCompletion(completion)
    await #expect(throws: CodexAccountClientError.loginAlreadyPending) {
      try await completionClient.startLogin(.deviceCode)
    }
    await #expect(throws: CodexAccountClientError.transitionInProgress) {
      try await completionClient.logout()
    }

    await transport.succeed(with: .object(["status": .string("canceled")]))
    #expect(try await cancelling.value == .cancelled)
    #expect(await startingClient.loginCompletion(for: loginID) == completion)

    await transport.enqueueResponse(challenge(named: "after-third-facade-cancel"))
    let replacement = try await completionClient.startLogin(.browser)
    #expect(replacement.loginID.rawValue == "after-third-facade-cancel")
  }

  @Test
  func sharesIdentifierReuseProtectionAcrossClientsOnOneTransport() async throws {
    let transport = GatedCodexAppServerTransport()
    let firstClient = CodexAccountClient(transport: transport)
    let secondClient = CodexAccountClient(transport: transport)
    _ = try await startAndCancelLogin(
      named: "shared-generation-id",
      client: firstClient,
      transport: transport,
      expectedRequestCount: 1
    )
    let secondStart = Task { try await secondClient.startLogin(.browser) }
    await transport.waitForRequest(count: 3)

    await transport.succeed(with: challenge(named: "shared-generation-id"))
    await #expect(throws: CodexAccountClientError.loginIdentifierReused) {
      try await secondStart.value
    }
  }

  @Test
  func rejectsASecondClientStartBeforeSendingOnTheSharedGeneration() async throws {
    let transport = GatedCodexAppServerTransport()
    let firstClient = CodexAccountClient(transport: transport)
    let secondClient = CodexAccountClient(transport: transport)
    let firstStart = Task { try await firstClient.startLogin(.browser) }
    await transport.waitForRequest()

    await #expect(throws: CodexAccountClientError.loginAlreadyPending) {
      try await secondClient.startLogin(.deviceCode)
    }
    #expect(await transport.requestCount() == 1)

    await transport.succeed(with: challenge(named: "generation-wide-active"))
    #expect(try await firstStart.value.loginID.rawValue == "generation-wide-active")
  }

  @Test
  func sharesCompletionCorrelationAcrossClientsOnOneTransport() async throws {
    let transport = GatedCodexAppServerTransport()
    let issuingClient = CodexAccountClient(transport: transport)
    let notificationClient = CodexAccountClient(transport: transport)
    let starting = Task { try await issuingClient.startLogin(.browser) }
    await transport.waitForRequest()
    await transport.succeed(with: challenge(named: "shared-completion"))
    let loginID = try await starting.value.loginID
    let sharedCompletion = try completion(for: loginID)

    try await notificationClient.acceptLoginCompletion(sharedCompletion)

    #expect(await issuingClient.loginCompletion(for: loginID) == sharedCompletion)
    #expect(await notificationClient.loginCompletion(for: loginID) == sharedCompletion)
    await #expect(throws: CodexAccountClientError.unexpectedLoginCompletion) {
      try await issuingClient.acceptLoginCompletion(sharedCompletion)
    }

    await transport.enqueueResponse(challenge(named: "after-shared-completion"))
    let replacement = try await issuingClient.startLogin(.browser)
    #expect(replacement.loginID.rawValue == "after-shared-completion")
  }

  @Test
  func earlyCompletionThroughAnotherClientCorrelatesWithTheSharedStart() async throws {
    let transport = GatedCodexAppServerTransport()
    let startingClient = CodexAccountClient(transport: transport)
    let notificationClient = CodexAccountClient(transport: transport)
    let starting = Task { try await startingClient.startLogin(.browser) }
    await transport.waitForRequest()
    let loginID = try CodexLoginID(rawValue: "cross-client-early")
    let earlyCompletion = try completion(for: loginID)

    try await notificationClient.acceptLoginCompletion(earlyCompletion)
    #expect(await startingClient.loginCompletion(for: loginID) == earlyCompletion)
    #expect(await notificationClient.loginCompletion(for: loginID) == earlyCompletion)
    await transport.succeed(with: challenge(named: loginID.rawValue))

    #expect(try await starting.value.loginID == loginID)
    await #expect(throws: CodexAccountClientError.unexpectedLoginCompletion) {
      try await startingClient.acceptLoginCompletion(earlyCompletion)
    }
  }

  @Test
  func crossClientCompletionDoesNotReleaseTheGenerationDuringCancellation() async throws {
    let transport = GatedCodexAppServerTransport()
    let cancellingClient = CodexAccountClient(transport: transport)
    let notificationClient = CodexAccountClient(transport: transport)
    let starting = Task { try await cancellingClient.startLogin(.browser) }
    await transport.waitForRequest()
    await transport.succeed(with: challenge(named: "shared-cancelling"))
    let loginID = try await starting.value.loginID
    let cancelling = Task { try await cancellingClient.cancelLogin(loginID) }
    await transport.waitForRequest(count: 2)

    try await notificationClient.acceptLoginCompletion(completion(for: loginID))
    await #expect(throws: CodexAccountClientError.loginAlreadyPending) {
      try await notificationClient.startLogin(.browser)
    }
    #expect(await transport.requestCount() == 2)

    await transport.succeed(with: .object(["status": .string("canceled")]))
    #expect(try await cancelling.value == .cancelled)
    await transport.enqueueResponse(challenge(named: "after-shared-cancel"))
    let replacement = try await notificationClient.startLogin(.browser)
    #expect(replacement.loginID.rawValue == "after-shared-cancel")
  }

  @Test
  func cancellationBeforeAResponseRetiresTheAmbiguousSharedGeneration() async throws {
    let transport = TestCodexAppServerTransport(
      outcomes: [
        .cancellation,
        .value(challenge(named: "after-pre-response-cancellation")),
      ]
    )
    let client = CodexAccountClient(transport: transport)

    await #expect(throws: CancellationError.self) {
      try await client.startLogin(.browser)
    }

    #expect(await transport.retirementCount() == 1)
    let replacementClient = CodexAccountClient(transport: transport)
    await #expect(throws: CodexAccountClientError.loginFlowGenerationRetired) {
      try await replacementClient.startLogin(.browser)
    }
    #expect(await transport.requests().count == 1)
  }

  @Test
  func cancellationAfterAResponseTombstonesTheIDAndRetiresTheGeneration() async throws {
    let transport = GatedCodexAppServerTransport()
    let client = CodexAccountClient(transport: transport)
    let starting = Task { try await client.startLogin(.browser) }
    await transport.waitForRequest()

    starting.cancel()
    await transport.succeed(with: challenge(named: "cancelled-response-id"))

    await #expect(throws: CancellationError.self) {
      try await starting.value
    }
    #expect(await transport.retirementCount() == 1)
    await transport.enqueueResponse(challenge(named: "cancelled-response-id"))
    let replacementClient = CodexAccountClient(transport: transport)
    await #expect(throws: CodexAccountClientError.loginFlowGenerationRetired) {
      try await replacementClient.startLogin(.browser)
    }
    #expect(await transport.requestCount() == 1)
  }

  @Test
  func malformedStartResponseRetiresTheGenerationBeforeReturning() async throws {
    let transport = GatedCodexAppServerTransport()
    let client = CodexAccountClient(transport: transport)
    let starting = Task { try await client.startLogin(.browser) }
    await transport.waitForRequest()

    await transport.succeed(with: .object(["type": .string("chatgpt")]))

    await #expect(throws: CodexAccountClientError.malformedResponse) {
      try await starting.value
    }
    #expect(await transport.retirementCount() == 1)
    await transport.enqueueResponse(challenge(named: "replacement-after-malformed"))
    let replacementClient = CodexAccountClient(transport: transport)
    await #expect(throws: CodexAccountClientError.loginFlowGenerationRetired) {
      try await replacementClient.startLogin(.browser)
    }
    #expect(await transport.requestCount() == 1)
  }

  @Test
  func sharesTheCapacityEdgeAcrossClientsOnOneTransport() async throws {
    let transport = try #require(
      TestCodexAppServerTransport(
        outcomes: [
          .value(challenge(named: "only-shared-slot")),
          .value(.object(["status": .string("canceled")])),
          .value(challenge(named: "capacity-bypass")),
        ],
        loginFlowHistoryCapacity: 1
      )
    )
    let firstClient = CodexAccountClient(transport: transport)
    let secondClient = CodexAccountClient(transport: transport)
    let challenge = try await firstClient.startLogin(.browser)
    #expect(try await firstClient.cancelLogin(challenge.loginID) == .cancelled)

    await #expect(throws: CodexAccountClientError.loginFlowHistoryExhausted) {
      try await secondClient.startLogin(.browser)
    }
    #expect(await transport.requests().count == 2)
  }

  @Test
  func enforcesTheExactDefaultSixtyFourFlowCapacityAcrossClients() async throws {
    var outcomes: [TestCodexAppServerTransportOutcome] = []
    for index in 0..<64 {
      outcomes.append(.value(challenge(named: "bounded-\(index)")))
      outcomes.append(.value(.object(["status": .string("canceled")])))
    }
    let transport = TestCodexAppServerTransport(outcomes: outcomes)
    let firstClient = CodexAccountClient(transport: transport)

    for index in 0..<64 {
      let challenge = try await firstClient.startLogin(.browser)
      #expect(challenge.loginID.rawValue == "bounded-\(index)")
      #expect(try await firstClient.cancelLogin(challenge.loginID) == .cancelled)
    }

    let secondClient = CodexAccountClient(transport: transport)
    await #expect(throws: CodexAccountClientError.loginFlowHistoryExhausted) {
      try await secondClient.startLogin(.browser)
    }
    #expect(await transport.requests().count == 128)
  }

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
    await #expect(throws: CodexAccountClientError.loginFlowGenerationRetired) {
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
    let transport = try #require(GatedCodexAppServerTransport(loginFlowHistoryCapacity: 2))
    let client = CodexAccountClient(transport: transport)
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
    await #expect(throws: CodexAccountClientError.loginFlowGenerationRetired) {
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

    let freshTransport = try #require(
      GatedCodexAppServerTransport(loginFlowHistoryCapacity: 2)
    )
    let freshClient = CodexAccountClient(transport: freshTransport)
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
    for capacity in [0, 65] {
      switch GatedCodexAppServerTransport(loginFlowHistoryCapacity: capacity) {
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
