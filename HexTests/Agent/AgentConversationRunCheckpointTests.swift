import Foundation
import HexCore
import HexIPC
import Testing

@testable import Hex

@Suite("Durable conversation run checkpoint storage")
struct AgentConversationRunCheckpointTests {
  @Test
  func checkpointRoundTripsExactRequestPartialRowAndCursor() async throws {
    let value = fixture()
    try await expectRoundTrip(archiveData(value.conversation, checkpoint: checkpoint(value)))
  }

  @Test
  func preAdmissionCheckpointHasNoInventedInvocationOrEventCursor() async throws {
    var value = fixture(sequence: 0, partial: false)
    value.gateway = nil
    value.invocation = nil
    try await expectRoundTrip(archiveData(value.conversation, checkpoint: checkpoint(value)))
  }

  @Test
  func journalOnlyCheckpointNeedsAnAnchorButNoInventedInvocation() async throws {
    var value = fixture()
    value.gateway = nil
    value.invocation = nil
    try await expectRoundTrip(archiveData(value.conversation, checkpoint: checkpoint(value)))
  }

  @Test
  func pendingApprovalQueuePreservesOrderAndUnresolvedToolCorrelations() async throws {
    var value = fixture(partial: false)
    let first = ToolCall(name: "inspect", arguments: [:])
    let second = ToolCall(name: "inspect_more", arguments: [:])
    value.conversation.history?.exchanges[1].messages.append(
      Message(role: .assistant, content: [.toolCall(first), .toolCall(second)]))
    let approvals = [first, second].map { call in
      AuthorizationRequest(
        runID: value.request.runID, toolCallID: call.id,
        capability: CapabilityID(rawValue: "filesystem.read"), operation: "Inspect files",
        resource: "/sample", details: ["readOnly": .boolean(true)], explanation: "Read the project")
    }
    try await expectRoundTrip(
      archiveData(
        value.conversation,
        checkpoint: checkpoint(value, approvals: approvals, hasToolEvidence: true)))
  }

  @Test
  func retryCheckpointRetainsOriginalPreCompactionRequest() async throws {
    var value = fixture(partial: false)
    let failedID = value.request.runID
    value.conversation.history?.exchanges[1].outcome = .failed
    let summary = try AgentContextCompaction(
      ownerRunID: failedID, sourceMessageIDs: value.request.initialMessages.dropLast().map(\.id),
      summaryText: "Earlier work completed.", providerID: ProviderID(rawValue: "fixture"),
      modelID: value.request.modelID, estimatedTokensBefore: 2_000, estimatedTokensAfter: 100)
    value.conversation.history?.compactions = [summary]
    let retryID = AgentRunID()
    let user = try #require(value.request.initialMessages.last)
    value.conversation.history?.exchanges.append(
      AgentConversationExchange(
        runID: retryID, messages: [user], outcome: .interrupted, lastEventSequence: 10,
        retryOfRunID: failedID))
    value.request = GatewayStartRunRequest(
      runID: retryID, modelID: value.request.modelID,
      initialMessages: value.request.initialMessages, options: value.request.options,
      toolChoice: value.request.toolChoice, workingDirectory: value.request.workingDirectory)
    try await expectRoundTrip(archiveData(value.conversation, checkpoint: checkpoint(value)))
  }

  @Test
  func oldV2ArchiveDoesNotGainARecoveryClaimOrChangeItsBytes() async throws {
    let value = fixture(partial: false)
    let data = try encoded(archive(value.conversation))
    #expect(!String(decoding: data, as: UTF8.self).contains("pendingRun"))
    try await expectRoundTrip(data)
  }

  @Test
  func legacyPendingRequestWithPriorArtifactOutputPreservesItsExactBytes() async throws {
    let (value, references) = try fixtureWithPriorArtifacts(count: 1)
    #expect(value.conversation.artifactInventory == nil)
    #expect(value.request.availableArtifacts.isEmpty)
    guard case .object(let requestObject) = try json(value.request) else {
      throw FixtureError.invalidFixture
    }
    #expect(requestObject["availableArtifacts"] == nil)
    let requestBytes = try encoded(value.request)

    let loaded = try await expectRoundTrip(
      archiveData(value.conversation, checkpoint: checkpoint(value)))

    let conversation = try #require(loaded.conversations.first)
    let restored = try #require(conversation.pendingRun?.request)
    #expect(restored.availableArtifacts.isEmpty)
    #expect(try encoded(restored) == requestBytes)
    #expect(try conversation.availableArtifacts(before: restored.runID) == references)
  }

  @Test
  func currentOutputBeyondRequestInventoryLimitRemainsDurableAndOrdered() async throws {
    var (value, priorReferences) = try fixtureWithPriorArtifacts(count: 256)
    value.request = GatewayStartRunRequest(
      runID: value.request.runID, modelID: value.request.modelID,
      initialMessages: value.request.initialMessages, options: value.request.options,
      toolChoice: value.request.toolChoice, workingDirectory: value.request.workingDirectory,
      availableArtifacts: priorReferences)
    let requestBytes = try encoded(value.request)
    let call = ToolCall(name: "inspect_current", arguments: [:])
    let currentReference = ArtifactReference(
      id: UUID(), runID: value.request.runID, toolCallID: call.id, mediaType: "text/plain",
      byteCount: 1, sha256: String(repeating: "b", count: 64), isComplete: true)
    value.conversation.history?.exchanges[1].messages.append(contentsOf: [
      Message(role: .assistant, content: [.toolCall(call)]),
      Message(
        role: .tool,
        content: [
          .toolResult(
            ToolResult(
              toolCallID: call.id, status: .success, output: .null, artifacts: [currentReference]))
        ]),
    ])
    let fullInventory = priorReferences + [currentReference]
    value.conversation.artifactInventory = fullInventory
    #expect(fullInventory.count == 257)

    let loaded = try await expectRoundTrip(
      archiveData(value.conversation, checkpoint: checkpoint(value, hasToolEvidence: true)))

    let conversation = try #require(loaded.conversations.first)
    let restored = try #require(conversation.pendingRun?.request)
    #expect(conversation.artifactInventory == fullInventory)
    #expect(try conversation.availableArtifacts() == fullInventory)
    #expect(try conversation.availableArtifacts(before: restored.runID) == priorReferences)
    #expect(restored.availableArtifacts == priorReferences)
    #expect(try encoded(restored) == requestBytes)
  }

  @Test
  func wrongRunCursorInvocationAndSequenceAreRejectedWithoutChangingBytes() async throws {
    let value = fixture()
    let record = try checkpoint(value)
    for (key, replacement) in [
      ("invocationID", JSONValue.null),
      ("gatewayInstanceID", .null),
      ("appliedSequence", .integer(9)),
      ("appliedSequence", .integer(0)),
      ("firstEventID", .null),
      ("firstEventID", .string("00000000-0000-0000-0000-000000000000")),
      ("gatewayInstanceID", .string("00000000-0000-0000-0000-000000000000")),
      ("invocationID", .string("00000000-0000-0000-0000-000000000000")),
    ] {
      try await expectRejected(
        archiveData(value.conversation, checkpoint: replacing(record, key, replacement)))
    }
    let wrong = GatewayStartRunRequest(
      runID: AgentRunID(), modelID: value.request.modelID,
      initialMessages: value.request.initialMessages)
    try await expectRejected(
      archiveData(value.conversation, checkpoint: replacing(record, "request", json(wrong))))
  }

  @Test
  func changedRequestContentInvalidOptionsAndWorkingDirectoryAreRejected() async throws {
    let value = fixture()
    let record = try checkpoint(value)
    var changed = value.request.initialMessages
    changed[0] = Message(id: changed[0].id, role: .user, content: [.text("Changed source")])
    let requests = [
      GatewayStartRunRequest(
        runID: value.request.runID, modelID: value.request.modelID, initialMessages: changed),
      GatewayStartRunRequest(
        runID: value.request.runID, modelID: ModelID(rawValue: ""),
        initialMessages: value.request.initialMessages),
      GatewayStartRunRequest(
        runID: value.request.runID, modelID: value.request.modelID,
        initialMessages: value.request.initialMessages,
        options: InferenceOptions(maxOutputTokens: 0)),
      GatewayStartRunRequest(
        runID: value.request.runID, modelID: value.request.modelID,
        initialMessages: value.request.initialMessages,
        workingDirectory: try #require(URL(string: "https://example.com/workspace"))),
    ]
    for request in requests {
      try await expectRejected(
        archiveData(value.conversation, checkpoint: replacing(record, "request", json(request))))
    }
  }

  @Test
  func unknownPartialRowAndWrongApprovalRunAreRejected() async throws {
    let value = fixture()
    let record = try checkpoint(value)
    try await expectRejected(
      archiveData(
        value.conversation,
        checkpoint: replacing(record, "streamingAssistantItemID", .string(UUID().uuidString))))
    let approval = AuthorizationRequest(
      runID: AgentRunID(), capability: CapabilityID(rawValue: "filesystem.read"),
      operation: "Read", explanation: "Read a file")
    try await expectRejected(
      archiveData(
        value.conversation,
        checkpoint: replacing(record, "pendingAuthorizations", .array([try json(approval)]))))
  }

  @Test
  func terminalOrNonLatestExchangeCannotBeMarkedAsPending() async throws {
    let value = fixture()
    var terminal = value.conversation
    terminal.history?.exchanges[1].outcome = .completed
    try await expectRejected(archiveData(terminal, checkpoint: checkpoint(value)))
    var nonLatest = value.conversation
    nonLatest.history?.exchanges.append(
      AgentConversationExchange(
        runID: AgentRunID(), messages: [Message(role: .user, content: [.text("Later")])]))
    try await expectRejected(archiveData(nonLatest, checkpoint: checkpoint(value)))
  }

  @Test
  func legacyV1CannotClaimCheckpointRecovery() async throws {
    let value = fixture()
    var legacy = value.conversation
    legacy.history = nil
    try await expectRejected(archiveData(legacy, checkpoint: checkpoint(value), schemaVersion: 1))
  }

  @Test
  func duplicateOrResolvedToolApprovalsCannotBeRestoredAsPending() async throws {
    var value = fixture(partial: false)
    let call = ToolCall(name: "inspect", arguments: [:])
    value.conversation.history?.exchanges[1].messages.append(
      Message(role: .assistant, content: [.toolCall(call)]))
    let approval = AuthorizationRequest(
      runID: value.request.runID, toolCallID: call.id,
      capability: CapabilityID(rawValue: "filesystem.read"), operation: "Inspect",
      explanation: "Read the project")
    try await expectRejected(
      archiveData(
        value.conversation,
        checkpoint: checkpoint(value, approvals: [approval, approval], hasToolEvidence: true)))
    try await expectRejected(
      archiveData(
        value.conversation,
        checkpoint: checkpoint(value, approvals: [approval], hasToolEvidence: false)))
    value.conversation.history?.exchanges[1].messages.append(
      Message(
        role: .tool,
        content: [
          .toolResult(ToolResult(toolCallID: call.id, status: .success, output: .null))
        ]))
    try await expectRejected(
      archiveData(
        value.conversation,
        checkpoint: checkpoint(value, approvals: [approval], hasToolEvidence: true)))
  }

  @Test
  func generatedStateCannotBeSavedAtAnUnobservedCursor() async throws {
    let value = fixture(sequence: 0)
    try await expectRejected(archiveData(value.conversation, checkpoint: checkpoint(value)))
    var generated = fixture(sequence: 0, partial: false)
    generated.conversation.history?.exchanges[1].messages.append(
      Message(role: .assistant, content: [.text("Generated before cursor")]))
    try await expectRejected(archiveData(generated.conversation, checkpoint: checkpoint(generated)))
  }

  @Test
  func invalidCheckpointSavePreservesTheLastCommittedSnapshot() async throws {
    let value = fixture()
    let data = try archiveData(value.conversation, checkpoint: checkpoint(value))
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.json")
    try writePrivate(data, to: url)
    let store = try AgentConversationStore(fileURL: url)
    let loaded = try #require(try await store.load())
    var conversation = try #require(loaded.conversations.first)
    conversation.pendingRun?.appliedSequence += 1

    await #expect(throws: (any Error).self) { try await store.save(archive(conversation)) }

    #expect(try Data(contentsOf: url) == data)
  }

  @Test
  func cancellationBeforeSaveDoesNotReplaceTheExistingArchive() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.json")
    let store = try AgentConversationStore(fileURL: url)
    let original = archive(fixture(partial: false).conversation)
    try await store.save(original)
    let data = try Data(contentsOf: url)
    let replacement = archive(AgentConversation(title: "Replacement"))
    let operation = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await store.save(replacement)
    }

    await #expect(throws: CancellationError.self) { try await operation.value }

    #expect(try Data(contentsOf: url) == data)
  }

  private struct Fixture {
    var conversation: AgentConversation
    var request: GatewayStartRunRequest
    var gateway: GatewayInstanceID? = GatewayInstanceID()
    var invocation: GatewayRunInvocationID? = GatewayRunInvocationID(rawValue: UUID())
    var sequence: UInt64
    var partialID: UUID?
  }

  private func fixture(sequence: UInt64 = 10, partial: Bool = true) -> Fixture {
    let earlier = AgentConversationExchange(
      runID: AgentRunID(),
      messages: [
        Message(role: .user, content: [.text("Earlier question")]),
        Message(role: .assistant, content: [.text("Earlier answer")]),
      ], outcome: .completed)
    let user = Message(role: .user, content: [.text("Continue")])
    let current = AgentConversationExchange(
      runID: AgentRunID(), messages: [user], outcome: .inProgress,
      lastEventSequence: sequence > 0 ? sequence : nil)
    let row = ConversationItem(role: .assistant, text: "Hel", isStreaming: true)
    let conversation = AgentConversation(
      title: "Recovery fixture", createdAt: Date(timeIntervalSinceReferenceDate: 0),
      transcript: partial ? [row] : [],
      history: AgentConversationHistory(exchanges: [earlier, current]))
    let request = GatewayStartRunRequest(
      runID: current.runID, modelID: ModelID(rawValue: "fixture-model"),
      initialMessages: earlier.messages + [user],
      options: InferenceOptions(maxOutputTokens: 512, temperature: 0.25, reasoningEffort: .low),
      toolChoice: .named("inspect"), workingDirectory: URL(fileURLWithPath: "/sample"))
    return Fixture(
      conversation: conversation, request: request, sequence: sequence,
      partialID: partial ? row.id : nil)
  }

  private func checkpoint(
    _ value: Fixture, approvals: [AuthorizationRequest] = [], hasToolEvidence: Bool = false
  ) throws -> JSONValue {
    var object: [String: JSONValue] = [
      "request": try json(value.request), "appliedSequence": .integer(Int64(value.sequence)),
      "pendingAuthorizations": .array(try approvals.map(json)),
      "hasToolEvidence": .boolean(hasToolEvidence), "cancellationRequested": .boolean(false),
    ]
    if let id = value.gateway { object["gatewayInstanceID"] = try json(id) }
    if let id = value.invocation { object["invocationID"] = try json(id) }
    if value.sequence > 0 { object["firstEventID"] = try json(AgentEventID()) }
    if let id = value.partialID { object["streamingAssistantItemID"] = .string(id.uuidString) }
    return .object(object)
  }

  private func fixtureWithPriorArtifacts(count: Int) throws -> (Fixture, [ArtifactReference]) {
    var value = fixture(partial: false)
    var earlier = try #require(value.conversation.history?.exchanges.first)
    let call = ToolCall(name: "inspect", arguments: [:])
    // Descending IDs make an accidental UUID sort observable after a real store round-trip.
    let references = try (1...count).reversed().map { ordinal in
      ArtifactReference(
        id: try #require(
          UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", ordinal))")),
        runID: earlier.runID, toolCallID: call.id, mediaType: "text/plain", byteCount: 1,
        sha256: String(repeating: "a", count: 64), isComplete: true)
    }
    earlier.messages.insert(
      contentsOf: [
        Message(role: .assistant, content: [.toolCall(call)]),
        Message(
          role: .tool,
          content: [
            .toolResult(
              ToolResult(
                toolCallID: call.id, status: .success, output: .null, artifacts: references))
          ]),
      ], at: 1)
    value.conversation.history?.exchanges[0] = earlier
    let user = try #require(value.request.initialMessages.last)
    value.request = GatewayStartRunRequest(
      runID: value.request.runID, modelID: value.request.modelID,
      initialMessages: earlier.messages + [user], options: value.request.options,
      toolChoice: value.request.toolChoice, workingDirectory: value.request.workingDirectory)
    return (value, references)
  }

  private func archive(_ conversation: AgentConversation, schemaVersion: UInt16 = 2)
    -> AgentConversationArchive
  {
    AgentConversationArchive(
      selectedConversationID: conversation.id, conversations: [conversation],
      schemaVersion: schemaVersion)
  }

  private func archiveData(
    _ conversation: AgentConversation, checkpoint: JSONValue, schemaVersion: UInt16 = 2
  ) throws -> Data {
    guard case .object(var object) = try json(archive(conversation, schemaVersion: schemaVersion)),
      case .array(let conversations)? = object["conversations"],
      case .object(var value)? = conversations.first
    else { throw FixtureError.invalidFixture }
    value["pendingRun"] = checkpoint
    object["conversations"] = .array([.object(value)])
    return try encoded(JSONValue.object(object))
  }

  private func replacing(_ value: JSONValue, _ key: String, _ replacement: JSONValue) throws
    -> JSONValue
  {
    guard case .object(var object) = value else { throw FixtureError.invalidFixture }
    object[key] = replacement
    return .object(object)
  }

  @discardableResult
  private func expectRoundTrip(_ data: Data) async throws -> AgentConversationArchive {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.json")
    try writePrivate(data, to: url)
    let store = try AgentConversationStore(fileURL: url)
    let loaded = try #require(try await store.load())
    #expect(try encoded(loaded) == data)
    #expect(try Data(contentsOf: url) == data)
    try await store.save(loaded)
    #expect(try Data(contentsOf: url) == data)
    return loaded
  }

  private func expectRejected(_ data: Data) async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.json")
    try writePrivate(data, to: url)
    let store = try AgentConversationStore(fileURL: url)
    await #expect(throws: (any Error).self) { try await store.load() }
    #expect(try Data(contentsOf: url) == data)
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("HexCheckpoint-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    return directory
  }

  private func writePrivate(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
  }

  private func json<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: encoded(value))
  }

  private func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }

  private enum FixtureError: Error { case invalidFixture }
}
