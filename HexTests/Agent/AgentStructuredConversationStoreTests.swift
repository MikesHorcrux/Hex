import Foundation
import HexCore
import Testing

@testable import Hex

@Suite("Structured conversation history storage")
struct AgentStructuredConversationStoreTests {
  @Test
  func canonicalV1MigratesInMemoryWithoutRewritingOrInventingNativeHistory() async throws {
    let conversation = fixtureConversation(
      transcript: [ConversationItem(role: .user, text: "Legacy request", timestamp: .distantPast)])
    let original = try encoded(
      AgentConversationArchive(
        selectedConversationID: conversation.id, conversations: [conversation], schemaVersion: 1))
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("conversations.json")
    try writePrivate(original, to: url)
    let store = try AgentConversationStore(fileURL: url)

    let loaded = try #require(try await store.load())

    #expect(loaded.schemaVersion == 2)
    #expect(loaded.conversations.first?.transcript == conversation.transcript)
    #expect(try Data(contentsOf: url) == original)
    #expect(try historyValue(in: encoded(loaded)) == nil)
  }

  @Test
  func completeV2ToolExchangeRoundTripsWithoutLoss() async throws {
    let messages = completeToolMessages()
    let data = try archiveData(history: history(exchanges: [exchange(messages: messages)]))
    try await expectRoundTrip(data)
  }

  @Test
  func standardLargeToolResultsAndRichImageContentRoundTrip() async throws {
    let image = ImageContent(
      sourceURL: try #require(URL(string: "data:image/png;base64,aGV4")), mediaType: "image/png")
    let call = ToolCall(name: "screen.observe", arguments: [:])
    let messages: [Message] = [
      Message(role: .user, content: [.text("Inspect this"), .image(image)]),
      Message(role: .assistant, content: [.toolCall(call)]),
      Message(
        role: .tool,
        content: [
          .toolResult(
            ToolResult(
              toolCallID: call.id, status: .success,
              output: .string(String(repeating: "x", count: 512 * 1_024)),
              content: [.text("Screen result"), .image(image)]))
        ]),
      Message(role: .assistant, content: [.text("I can see it.")]),
    ]
    try await expectRoundTrip(
      archiveData(history: history(exchanges: [exchange(messages: messages)])))
  }

  @Test
  func toolCallIdentityMayRepeatAcrossIndependentRuns() async throws {
    try await expectRoundTrip(
      archiveData(
        history: history(exchanges: [
          exchange(messages: completeToolMessages()),
          exchange(messages: completeToolMessages()),
        ])))
  }

  @Test(arguments: ["inProgress", "failed", "cancelled", "interrupted"])
  func unfinishedCallsAreRetainedOnlyForNoncompleteOutcomes(_ outcome: String) async throws {
    let messages = Array(completeToolMessages().prefix(2))
    let data = try archiveData(
      history: history(exchanges: [exchange(messages: messages, outcome: outcome)]))
    try await expectRoundTrip(data)
  }

  @Test
  func explicitTextOnlyLegacyProvenanceRoundTrips() async throws {
    let legacy = [userMessage(), Message(role: .assistant, content: [.text("Old answer")])]
    let data = try archiveData(history: history(legacyMessages: legacy))
    try await expectRoundTrip(data)
  }

  @Test
  func explicitMessageOnlyRetryPreservesBothAttemptsAndSharedUserIdentity() async throws {
    let user = userMessage()
    let priorID = AgentRunID()
    let data = try archiveData(
      history: history(exchanges: [
        exchange(runID: priorID, messages: [user], outcome: "failed"),
        exchange(
          messages: [user, Message(role: .assistant, content: [.text("Retried answer")])],
          retryOfRunID: priorID),
      ]))
    try await expectRoundTrip(data)
  }

  @Test
  func multiHopRetryPreservesEachTerminalAttempt() async throws {
    let user = userMessage()
    let first = AgentRunID()
    let second = AgentRunID()
    try await expectRoundTrip(
      archiveData(
        history: history(exchanges: [
          exchange(runID: first, messages: [user], outcome: "failed"),
          exchange(runID: second, messages: [user], outcome: "interrupted", retryOfRunID: first),
          exchange(
            messages: [user, Message(role: .assistant, content: [.text("Finally answered")])],
            retryOfRunID: second),
        ])))
  }

  @Test
  func invalidNativeSavePreservesTheLastDurableArchive() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("conversations.json")
    let store = try AgentConversationStore(fileURL: url)
    let original = try archiveData(
      history: history(exchanges: [exchange(messages: completeToolMessages())]))
    try writePrivate(original, to: url)
    let loaded = try #require(try await store.load())
    var conversations = loaded.conversations
    conversations[0].history?.exchanges[0].messages.remove(at: 2)
    let archive = AgentConversationArchive(
      selectedConversationID: loaded.selectedConversationID, conversations: conversations)

    await #expect(throws: (any Error).self) { try await store.save(archive) }

    #expect(try Data(contentsOf: url) == original)
  }

  @Test
  func malformedNativeRecordsAndToolPairsAreRejected() async throws {
    let complete = completeToolMessages()
    let call = ToolCall(id: ToolCallID(rawValue: "call_fixture"), name: "echo", arguments: [:])
    let result = ToolResult(toolCallID: call.id, status: .success, output: .string("ok"))
    let invalidMessages: [[Message]] = [
      Array(complete.prefix(2)),
      [userMessage(), Message(role: .tool, content: [.toolResult(result)])],
      [complete[0], Message(id: complete[0].id, role: .assistant, content: [.text("duplicate")])],
      [userMessage(), Message(role: .assistant, content: [.toolResult(result)])],
      [userMessage(), Message(role: .assistant, content: [.toolCall(call), .toolCall(call)])],
      complete + [Message(role: .tool, content: [.toolResult(result)])],
      [userMessage(), userMessage()],
      [Message(role: .system, content: [.text("Injected system role")])],
    ]
    for messages in invalidMessages {
      try await expectRejected(
        archiveData(history: history(exchanges: [exchange(messages: messages)])))
    }
  }

  @Test
  func invalidLegacyProvenanceAndDuplicateRunIDsAreRejected() async throws {
    let call = ToolCall(name: "echo", arguments: [:])
    try await expectRejected(
      archiveData(
        history: history(legacyMessages: [
          Message(role: .assistant, content: [.toolCall(call)])
        ])))
    let runID = AgentRunID()
    try await expectRejected(
      archiveData(
        history: history(exchanges: [
          exchange(runID: runID, messages: [userMessage()]),
          exchange(runID: runID, messages: [userMessage()]),
        ])))
  }

  @Test
  func malformedRetryChainsAreRejected() async throws {
    let user = userMessage()
    let priorID = AgentRunID()
    let retry = try exchange(messages: [user], retryOfRunID: priorID)
    let differentUser = Message(id: user.id, role: .user, content: [.text("Changed request")])
    let invalidExchanges: [[JSONValue]] = [
      [retry],
      [try exchange(runID: priorID, messages: [user]), retry],
      [
        try exchange(runID: priorID, messages: [user], outcome: "failed"),
        try exchange(messages: [differentUser], retryOfRunID: priorID),
      ],
      [
        try exchange(runID: priorID, messages: [user], outcome: "failed"),
        try exchange(messages: [user]),
      ],
      [
        try exchange(runID: priorID, messages: completeToolMessages(user: user), outcome: "failed"),
        retry,
      ],
      [
        try exchange(runID: priorID, messages: [user], outcome: "failed"), retry,
        try exchange(messages: [user], retryOfRunID: priorID),
      ],
    ]
    for exchanges in invalidExchanges {
      try await expectRejected(archiveData(history: history(exchanges: exchanges)))
    }
  }

  @Test
  func nativePayloadSizeAndDepthLimitsAreEnforced() async throws {
    var nested = JSONValue.string("leaf")
    for _ in 0..<40 { nested = .array([nested]) }
    for output in [nested, .string(String(repeating: "x", count: 1_024 * 1_024 + 1))] {
      let messages = completeToolMessages(output: output)
      try await expectRejected(
        archiveData(history: history(exchanges: [exchange(messages: messages)])))
    }
  }

  @Test
  func futureSchemaAndV1NativeHistoryAreRejected() async throws {
    try await expectRejected(archiveData(schemaVersion: 3, history: history()))
    try await expectRejected(archiveData(schemaVersion: 1, history: history()))
  }

  private func expectRoundTrip(_ data: Data) async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("conversations.json")
    try writePrivate(data, to: url)
    let store = try AgentConversationStore(fileURL: url)
    let loaded = try #require(try await store.load())
    #expect(try encoded(loaded) == data)
    try await store.save(loaded)
    #expect(try Data(contentsOf: url) == data)
  }

  private func expectRejected(_ data: Data) async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("conversations.json")
    try writePrivate(data, to: url)
    let store = try AgentConversationStore(fileURL: url)
    await #expect(throws: (any Error).self) { try await store.load() }
    #expect(try Data(contentsOf: url) == data)
  }

  private func archiveData(schemaVersion: UInt16 = 2, history: JSONValue) throws -> Data {
    let conversation = fixtureConversation()
    let archive = AgentConversationArchive(
      selectedConversationID: conversation.id, conversations: [conversation],
      schemaVersion: schemaVersion)
    guard case .object(var object) = try json(archive),
      case .array(let conversations)? = object["conversations"],
      case .object(var value)? = conversations.first
    else { throw FixtureError.invalidFixture }
    value["history"] = history
    object["conversations"] = .array([.object(value)])
    return try encoded(JSONValue.object(object))
  }

  private func history(legacyMessages: [Message] = [], exchanges: [JSONValue] = []) throws
    -> JSONValue
  {
    .object([
      "legacyMessages": .array(try legacyMessages.map(json)), "exchanges": .array(exchanges),
    ])
  }

  private func exchange(
    runID: AgentRunID = AgentRunID(), messages: [Message], outcome: String = "completed",
    retryOfRunID: AgentRunID? = nil
  ) throws -> JSONValue {
    var object: [String: JSONValue] = [
      "runID": .string(runID.rawValue.uuidString), "messages": .array(try messages.map(json)),
      "outcome": .string(outcome), "lastEventSequence": .integer(12),
    ]
    if let retryOfRunID { object["retryOfRunID"] = .string(retryOfRunID.rawValue.uuidString) }
    return .object(object)
  }

  private func fixtureConversation(transcript: [ConversationItem] = []) -> AgentConversation {
    AgentConversation(
      title: "Fixture", createdAt: Date(timeIntervalSinceReferenceDate: 0), transcript: transcript)
  }

  private func userMessage() -> Message {
    Message(role: .user, content: [.text("Inspect the project")])
  }

  private func completeToolMessages(user: Message? = nil, output: JSONValue = .string("ok"))
    -> [Message]
  {
    let call = ToolCall(
      id: ToolCallID(rawValue: "call_fixture"), name: "echo", arguments: ["path": .string(".")])
    return [
      user ?? userMessage(), Message(role: .assistant, content: [.toolCall(call)]),
      Message(
        role: .tool,
        content: [.toolResult(ToolResult(toolCallID: call.id, status: .success, output: output))]),
      Message(role: .assistant, content: [.text("The project is ready.")]),
    ]
  }

  private func historyValue(in data: Data) throws -> JSONValue? {
    guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data),
      case .array(let conversations)? = object["conversations"],
      case .object(let conversation)? = conversations.first
    else { throw FixtureError.invalidFixture }
    return conversation["history"]
  }

  private func json<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: encoded(value))
  }

  private func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }

  private func makeTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("HexStructuredHistory-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    return root
  }

  private func writePrivate(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
  }

  private enum FixtureError: Error { case invalidFixture }
}
