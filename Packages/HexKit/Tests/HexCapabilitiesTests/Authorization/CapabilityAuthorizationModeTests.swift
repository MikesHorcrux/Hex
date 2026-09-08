import Foundation
import HexCapabilities
import HexCore
import Testing

@Suite("Three-mode capability approval")
struct CapabilityAuthorizationModeTests {
  @Test
  func approveForMeAllowsOnlyExactScopedLocalObservation() async throws {
    let prompter = CountingPrompter()
    let center = CapabilityAuthorizationCenter(prompter: prompter, authorizationMode: .approveForMe)
    let runID = AgentRunID()
    let artifactID = UUID().uuidString
    let digest = String(repeating: "a", count: 64)
    let reads: [AuthorizationRequest] = [
      request(runID: runID, operation: "read"),
      request(runID: runID, operation: "list"),
      request(runID: runID, operation: "search"),
      request(
        runID: runID, capability: "personal.memory.read", operation: "list",
        resource: "profile-scope:main", details: ["scope": .string("main")]),
      request(
        runID: runID, capability: "personal.memory.read", operation: "search",
        resource: "profile-scope:main", details: ["scope": .string("main")]),
      request(
        runID: runID, capability: "artifact.read", operation: "list",
        resource: "conversation-output-catalog:\(runID.rawValue.uuidString)"),
      request(
        runID: runID, capability: "artifact.read", operation: "read",
        resource: "artifact:\(artifactID):sha256:\(digest)",
        details: ["artifact_id": .string(artifactID), "sha256": .string(digest)]),
      request(
        runID: runID, capability: "artifact.read", operation: "search",
        resource: "artifact:\(artifactID):sha256:\(digest)",
        details: ["artifact_id": .string(artifactID), "sha256": .string(digest)]),
      request(
        runID: runID, capability: "mac.application.read", operation: "list-running-applications",
        resource: "mac:running-applications"),
    ]

    for read in reads {
      #expect(try await center.authorize(read) == .allow)
    }
    #expect(await prompter.requestCount() == 0)
  }

  @Test
  func approveForMePromptsForEffectsUnknownToolsAndLookalikeReadScopes() async throws {
    let prompter = CountingPrompter()
    let center = CapabilityAuthorizationCenter(prompter: prompter, authorizationMode: .approveForMe)
    let requests = [
      request(capability: "workspace.write", operation: "write"),
      request(operation: "write"),
      request(capability: "process.execute", operation: "run"),
      request(capability: "network.read", operation: "fetch", resource: "https://example.com"),
      request(capability: "browser.read", operation: "navigate", resource: "https://example.com"),
      request(capability: "personal.memory.write", operation: "remember"),
      request(capability: "mac.accessibility.read", operation: "snapshot-accessibility-tree"),
      request(capability: "mac.application.read", operation: "activate"),
      request(
        capability: "mac.application.read", operation: "list-running-applications",
        resource: "other"),
      request(capability: "mcp_6_server_workspace.read", operation: "call"),
      request(capability: "workspace.read.safe", operation: "read"),
      request(
        capability: "unknown.read", operation: "read", details: ["readOnlyHint": .boolean(true)]),
      request(resource: nil),
      request(resource: "relative/path"),
      request(resource: "/workspace/../outside"),
      request(resource: "/workspace/./file"),
      request(resource: "/workspace/file\nother"),
      request(toolCallID: nil),
      request(
        capability: "personal.memory.read", operation: "list", resource: "profile-scope:main"),
      request(
        capability: "personal.memory.read", operation: "search", resource: "profile-scope:other",
        details: ["scope": .string("main")]),
      request(
        capability: "artifact.read", operation: "list",
        resource: "conversation-output-catalog:\(AgentRunID().rawValue.uuidString)"),
      request(capability: "artifact.read", operation: "read", resource: "artifact:unbound"),
    ]

    for request in requests {
      #expect(try await center.authorize(request) == .deny(reason: "Needs approval"))
    }
    #expect(await prompter.requestCount() == requests.count)
  }

  @Test
  func perRunAskTightensFullAccessWithoutChangingOtherRuns() async throws {
    let prompter = CountingPrompter()
    let center = CapabilityAuthorizationCenter(prompter: prompter, authorizationMode: .fullAccess)
    let constrained = request()
    try await center.beginRun(constrained.runID, authorizationMode: .askEveryTime)

    #expect(try await center.authorize(constrained) == .deny(reason: "Needs approval"))
    #expect(try await center.authorize(request()) == .allow)
    #expect(await prompter.requestCount() == 1)
  }

  @Test
  func perRunFullAccessDoesNotLeakAuthorityAfterRunEnds() async throws {
    let prompter = CountingPrompter()
    let center = CapabilityAuthorizationCenter(prompter: prompter)
    let mutation = request(capability: "workspace.write", operation: "write")
    try await center.beginRun(mutation.runID, authorizationMode: .fullAccess)

    #expect(try await center.authorize(mutation) == .allow)
    await center.endRun(mutation.runID)
    #expect(try await center.authorize(mutation) == .deny(reason: "Needs approval"))
    #expect(await prompter.requestCount() == 1)
  }

  @Test
  func pinnedModesCannotChangeAndAutomaticReadApprovalCreatesNoGrant() async throws {
    let prompter = CountingPrompter()
    let center = CapabilityAuthorizationCenter(prompter: prompter)
    let read = request()
    try await center.beginRun(read.runID, authorizationMode: .approveForMe)
    try await center.beginRun(read.runID, authorizationMode: .approveForMe)
    #expect(try await center.authorize(read) == .allow)
    await #expect(throws: AuthorizationPolicyError.runPolicyAlreadyEstablished) {
      try await center.beginRun(read.runID, authorizationMode: .fullAccess)
    }
    await center.endRun(read.runID)
    try await center.beginRun(read.runID, authorizationMode: .askEveryTime)
    #expect(try await center.authorize(read) == .deny(reason: "Needs approval"))
  }

  @Test
  func explicitGrantsRemainValidInTheMoreSelectiveMode() async throws {
    let prompter = CountingPrompter(response: .allow(scope: .session))
    let center = CapabilityAuthorizationCenter(prompter: prompter)
    let mutation = request(capability: "workspace.write", operation: "write")
    #expect(try await center.authorize(mutation) == .allow)
    try await center.beginRun(mutation.runID, authorizationMode: .approveForMe)
    #expect(try await center.authorize(mutation) == .allow)
    #expect(await prompter.requestCount() == 1)
  }

  @Test
  func allModesValidateBeforeAllowingAndRunPolicyCapacityIsReleased() async throws {
    let configuration = try #require(
      CapabilityAuthorizationCenterConfiguration(
        maximumCapabilityBytes: 256, maximumOperationBytes: 256,
        maximumResourceBytes: 16_384, maximumExplanationBytes: 16_384,
        maximumDetailsBytes: 65_536, maximumRunGrants: 1, maximumSessionGrants: 1))
    let center = CapabilityAuthorizationCenter(
      configuration: configuration, authorizationMode: .fullAccess)
    let runID = AgentRunID()
    try await center.beginRun(runID, authorizationMode: nil)
    await #expect(throws: CapabilityAuthorizationCenterError.self) {
      try await center.beginRun(AgentRunID(), authorizationMode: .fullAccess)
    }
    await #expect(throws: CapabilityAuthorizationCenterError.self) {
      try await center.authorize(request(runID: runID, operation: " read"))
    }
    await center.endRun(runID)
    try await center.beginRun(AgentRunID(), authorizationMode: .approveForMe)
  }

  private func request(
    runID: AgentRunID = AgentRunID(), toolCallID: ToolCallID? = ToolCallID(rawValue: "read-1"),
    capability: String = "workspace.read", operation: String = "read",
    resource: String? = "/workspace/file", details: [String: JSONValue] = [:]
  ) -> AuthorizationRequest {
    AuthorizationRequest(
      runID: runID, toolCallID: toolCallID, capability: CapabilityID(rawValue: capability),
      operation: operation, resource: resource, details: details,
      explanation: "The model says this operation is safe and read-only.")
  }

  private actor CountingPrompter: AuthorizationPrompting {
    private var count = 0
    private let response: AuthorizationPromptResponse

    init(response: AuthorizationPromptResponse = .deny(reason: "Needs approval")) {
      self.response = response
    }

    func requestDecision(for request: AuthorizationRequest) async throws
      -> AuthorizationPromptResponse
    {
      count += 1
      return response
    }

    func requestCount() -> Int { count }
  }
}
