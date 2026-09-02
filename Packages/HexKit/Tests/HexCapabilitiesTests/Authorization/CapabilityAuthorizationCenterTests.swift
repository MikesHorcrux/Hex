import Foundation
import HexCapabilities
import HexCore
import Testing

@Suite("Capability authorization center")
struct CapabilityAuthorizationCenterTests {
  @Test
  func defaultCompositionDenies() async throws {
    let center = CapabilityAuthorizationCenter()

    let decision = try await center.authorize(request())

    #expect(decision == .deny(reason: "No interactive authorization prompt is available."))
  }

  @Test
  func fullAccessAllowsOnlyAfterRequestValidation() async throws {
    let prompter = ScriptedPrompter(responses: [.deny(reason: "must not prompt")])
    let center = CapabilityAuthorizationCenter(
      prompter: prompter,
      automaticallyAllowsValidatedRequests: true
    )

    #expect(try await center.authorize(request()) == .allow)
    await #expect(throws: CapabilityAuthorizationCenterError.self) {
      try await center.authorize(request(operation: " invalid"))
    }
    #expect(await prompter.requestCount() == 0)
  }

  @Test
  func onceGrantPromptsForEveryRequest() async throws {
    let prompter = ScriptedPrompter(responses: [.allow(scope: .once), .allow(scope: .once)])
    let center = CapabilityAuthorizationCenter(prompter: prompter)
    let request = request()

    #expect(try await center.authorize(request) == .allow)
    #expect(try await center.authorize(request) == .allow)
    #expect(await prompter.requestCount() == 2)
  }

  @Test
  func runGrantIsExactAndCanBeEnded() async throws {
    let prompter = ScriptedPrompter(
      responses: [
        .allow(scope: .run),
        .deny(reason: "different run"),
        .deny(reason: "ended"),
      ]
    )
    let center = CapabilityAuthorizationCenter(prompter: prompter)
    let first = request()

    #expect(try await center.authorize(first) == .allow)
    #expect(try await center.authorize(first) == .allow)
    #expect(
      try await center.authorize(request(runID: AgentRunID()))
        == .deny(reason: "different run")
    )

    await center.endRun(first.runID)
    #expect(try await center.authorize(first) == .deny(reason: "ended"))
    #expect(await prompter.requestCount() == 3)
  }

  @Test
  func sessionGrantRequiresExactCapabilityOperationAndResource() async throws {
    let prompter = ScriptedPrompter(
      responses: [
        .allow(scope: .session),
        .deny(reason: "different resource"),
        .deny(reason: "different operation"),
        .deny(reason: "different capability"),
      ]
    )
    let center = CapabilityAuthorizationCenter(prompter: prompter)
    let first = request()

    #expect(try await center.authorize(first) == .allow)
    #expect(try await center.authorize(request(runID: AgentRunID())) == .allow)
    #expect(
      try await center.authorize(request(resource: "/workspace/other"))
        == .deny(reason: "different resource")
    )
    #expect(
      try await center.authorize(request(operation: "write"))
        == .deny(reason: "different operation")
    )
    #expect(
      try await center.authorize(request(capability: "filesystem.write"))
        == .deny(reason: "different capability")
    )
  }

  @Test
  func sharedGrantStoreIsReusedAcrossAuthorizationCenters() async throws {
    let store = VolatileAuthorizationGrantStore()
    let firstPrompter = ScriptedPrompter(responses: [.allow(scope: .persistent)])
    let firstCenter = CapabilityAuthorizationCenter(
      prompter: firstPrompter,
      persistentStore: store
    )
    let request = request()

    #expect(try await firstCenter.authorize(request) == .allow)

    let secondPrompter = ScriptedPrompter(responses: [.deny(reason: "must not prompt")])
    let secondCenter = CapabilityAuthorizationCenter(
      prompter: secondPrompter,
      persistentStore: store
    )
    #expect(try await secondCenter.authorize(request) == .allow)
    #expect(await secondPrompter.requestCount() == 0)

    try await secondCenter.revokePersistentGrant(AuthorizationGrantKey(request: request))
    #expect(
      try await secondCenter.authorize(request)
        == .deny(reason: "must not prompt")
    )
  }

  @Test
  func persistentChoiceFailsWhenDurableStoreIsNotComposed() async throws {
    let center = CapabilityAuthorizationCenter(
      prompter: ScriptedPrompter(responses: [.allow(scope: .persistent)])
    )

    await #expect(throws: CapabilityAuthorizationCenterError.persistentStoreUnavailable) {
      try await center.authorize(request())
    }
  }

  @Test
  func invalidAndOversizedRequestsFailBeforePrompt() async throws {
    let prompter = ScriptedPrompter(responses: [.allow(scope: .once)])
    let configuration = try #require(
      CapabilityAuthorizationCenterConfiguration(
        maximumCapabilityBytes: 8,
        maximumOperationBytes: 8,
        maximumResourceBytes: 8,
        maximumExplanationBytes: 8,
        maximumDetailsBytes: 8,
        maximumRunGrants: 1,
        maximumSessionGrants: 1
      )
    )
    let center = CapabilityAuthorizationCenter(
      prompter: prompter,
      configuration: configuration
    )

    await #expect(throws: CapabilityAuthorizationCenterError.self) {
      try await center.authorize(request(capability: " leading"))
    }
    await #expect(throws: CapabilityAuthorizationCenterError.self) {
      try await center.authorize(request(resource: "123456789"))
    }
    await #expect(throws: CapabilityAuthorizationCenterError.self) {
      try await center.authorize(request(details: ["long": .string("123456789")]))
    }
    #expect(await prompter.requestCount() == 0)
  }

  @Test
  func grantCapacityFailsClosedAndEndingRunReleasesIt() async throws {
    let configuration = try #require(
      CapabilityAuthorizationCenterConfiguration(
        maximumCapabilityBytes: 256,
        maximumOperationBytes: 256,
        maximumResourceBytes: 256,
        maximumExplanationBytes: 256,
        maximumDetailsBytes: 256,
        maximumRunGrants: 1,
        maximumSessionGrants: 1
      )
    )
    let prompter = ScriptedPrompter(
      responses: [
        .allow(scope: .run),
        .allow(scope: .run),
        .allow(scope: .run),
      ]
    )
    let center = CapabilityAuthorizationCenter(
      prompter: prompter,
      configuration: configuration
    )
    let first = request(runID: AgentRunID())
    let second = request(runID: AgentRunID())

    #expect(try await center.authorize(first) == .allow)
    await #expect(throws: CapabilityAuthorizationCenterError.self) {
      try await center.authorize(second)
    }
    await center.endRun(first.runID)
    #expect(try await center.authorize(second) == .allow)
  }

  @Test
  func cancellationAndStoreFailuresNeverBecomeAllows() async throws {
    let slowPrompter = ScriptedPrompter(
      responses: [.allow(scope: .once)],
      delay: .seconds(30)
    )
    let center = CapabilityAuthorizationCenter(prompter: slowPrompter)
    let task = Task {
      try await center.authorize(request())
    }
    while await slowPrompter.requestCount() == 0 {
      await Task.yield()
    }
    task.cancel()
    await #expect(throws: CancellationError.self) {
      try await task.value
    }

    let failingStore = FailingGrantStore()
    let persistentCenter = CapabilityAuthorizationCenter(
      prompter: ScriptedPrompter(responses: [.allow(scope: .persistent)]),
      persistentStore: failingStore
    )
    await #expect(throws: FailingGrantStore.StoreError.self) {
      try await persistentCenter.authorize(request())
    }
  }

  private func request(
    runID: AgentRunID = AgentRunID(),
    capability: String = "fs.read",
    operation: String = "read",
    resource: String? = "/workspace/file",
    details: [String: JSONValue] = [:]
  ) -> AuthorizationRequest {
    AuthorizationRequest(
      runID: runID,
      toolCallID: ToolCallID(rawValue: "call-1"),
      capability: CapabilityID(rawValue: capability),
      operation: operation,
      resource: resource,
      details: details,
      explanation: "Read a workspace file."
    )
  }

  actor ScriptedPrompter: AuthorizationPrompting {
    private var responses: [AuthorizationPromptResponse]
    private let delay: Duration?
    private var requests: [AuthorizationRequest] = []

    init(
      responses: [AuthorizationPromptResponse],
      delay: Duration? = nil
    ) {
      self.responses = responses
      self.delay = delay
    }

    func requestDecision(
      for request: AuthorizationRequest
    ) async throws -> AuthorizationPromptResponse {
      requests.append(request)
      if let delay {
        try await Task.sleep(for: delay)
      }
      guard !responses.isEmpty else {
        return .deny(reason: "No scripted response remains.")
      }
      return responses.removeFirst()
    }

    func requestCount() -> Int {
      requests.count
    }
  }

  actor FailingGrantStore: AuthorizationGrantStore {
    enum StoreError: Error {
      case unavailable
    }

    func contains(_ key: AuthorizationGrantKey) throws -> Bool {
      false
    }

    func insert(_ key: AuthorizationGrantKey) throws {
      throw StoreError.unavailable
    }

    func remove(_ key: AuthorizationGrantKey) throws {}

    func removeAll() throws {}
  }
}
