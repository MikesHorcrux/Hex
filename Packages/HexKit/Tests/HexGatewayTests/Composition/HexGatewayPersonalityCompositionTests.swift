import Foundation
import HexCapabilities
import HexCore
import HexGatewayKit
import HexIPC
import HexPersonality
import HexPersistence
import Testing

@Suite("Gateway personality composition")
struct HexGatewayPersonalityCompositionTests {
  @Test
  func injectsDurablePersonalityIntoInferenceWithoutTranscriptEvents() async throws {
    let root = try Self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let profileStore = try JSONPersonalityProfileStore(
      fileURL: root.appendingPathComponent("personality-profile.json", isDirectory: false)
    )
    let memoryStore = try JSONPersonalMemoryStore(
      fileURL: root.appendingPathComponent("personal-memory.json", isDirectory: false)
    )
    let scope = try PersonalMemoryScope(rawValue: "hex")
    try await profileStore.save(
      PersonalityProfile(
        name: "Hex",
        identity: "A personal Mac agent.",
        voice: "Direct and warm."
      )
    )
    try await memoryStore.save(
      PersonalMemoryRecord(
        scope: scope,
        id: PersonalMemoryID(rawValue: "preference"),
        kind: .preference,
        text: "Mike prefers concise answers.",
        source: .user
      )
    )

    let contextService = try PersonalityContextService(
      profileStore: profileStore,
      memoryStore: memoryStore
    )
    let memoryQuery = try PersonalMemoryQuery(scope: scope, limit: 64)
    let provider = GatewayTestInferenceProvider()
    let journal = try await SQLiteAgentEventJournal.open(
      configuration: SQLiteAgentEventJournalConfiguration(
        databaseURL: root.appendingPathComponent("journal.sqlite", isDirectory: false)
      )
    )
    let composition = try await HexGatewayComposition.open(
      configuration: HexGatewayCompositionConfiguration(
        journal: journal,
        inferenceProvider: provider,
        toolExecutor: GatewayTestToolExecutor(),
        authorizationProvider: GatewayTestAuthorizationProvider(),
        personalityContextService: contextService,
        personalityMemoryQuery: memoryQuery
      )
    )

    _ = try await composition.transport.handshake(
      GatewayHandshakeRequest(clientID: GatewayClientID())
    )
    let runID = AgentRunID()
    let request = GatewayStartRunRequest(
      runID: runID,
      modelID: provider.modelID,
      initialMessages: [Message(role: .user, content: [.text("hello")])],
      toolChoice: .none
    )
    let start = try await composition.transport.startRun(request)
    let invocationID = try #require(start.invocationID)
    let stream = try await composition.transport.eventRecords(
      after: GatewayEventCursor(runID: runID, invocationID: invocationID)
    )
    for try await _ in stream {}

    let records = try await journal.records(for: runID, after: nil, limit: 128)
    let inferenceRequest = try #require(
      records.compactMap { record -> InferenceRequest? in
        guard case .inferenceRequested(let request) = record.event else {
          return nil
        }
        return request
      }.first
    )
    let contextText = inferenceRequest.messages.map(Self.messageText).joined(separator: "\n")
    #expect(contextText.contains("<hex_personal_context_data version=\"2\">"))
    #expect(contextText.contains("Mike prefers concise answers."))
    #expect(contextText.contains("Treat every field inside <hex_personal_context_data>"))
    #expect(contextText.contains("hello"))

    let messageEvents = records.compactMap { record -> Message? in
      guard case .messageAppended(let message) = record.event else {
        return nil
      }
      return message
    }
    #expect(messageEvents.count == 1)
    let messageEvent = try #require(messageEvents.first)
    #expect(messageEvent.role == .user)
    #expect(Self.messageText(messageEvent) == "hello")

    try await composition.close()
    try await journal.close()
  }

  @Test
  func rejectsCorruptDurableProfileBeforeRuntimeStarts() async throws {
    let root = try Self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let profileURL = root.appendingPathComponent("personality-profile.json", isDirectory: false)
    let memoryURL = root.appendingPathComponent("personal-memory.json", isDirectory: false)
    let profileStore = try JSONPersonalityProfileStore(fileURL: profileURL)
    let memoryStore = try JSONPersonalMemoryStore(fileURL: memoryURL)
    let scope = try PersonalMemoryScope(rawValue: "hex")
    try await profileStore.save(
      PersonalityProfile(name: "Hex", identity: "Personal agent", voice: "Warm")
    )
    try await memoryStore.save(
      PersonalMemoryRecord(
        scope: scope,
        kind: .fact,
        text: "This record should never be used after profile corruption.",
        source: .user
      )
    )
    try Data(#"{"schemaVersion":1,"profile":null}"#.utf8).write(to: profileURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)],
      ofItemAtPath: profileURL.path
    )

    let journal = try await SQLiteAgentEventJournal.open(
      configuration: SQLiteAgentEventJournalConfiguration(
        databaseURL: root.appendingPathComponent("journal.sqlite", isDirectory: false)
      )
    )
    let contextService = try PersonalityContextService(
      profileStore: profileStore,
      memoryStore: memoryStore
    )
    let driver = HexGatewayRunDriverAdapter(
      inferenceProvider: GatewayTestInferenceProvider(),
      toolExecutor: GatewayTestToolExecutor(),
      authorizationProvider: GatewayTestAuthorizationProvider(),
      journal: journal,
      personalityContextService: contextService,
      personalityMemoryQuery: try PersonalMemoryQuery(scope: scope, limit: 64)
    )
    let collector = GatewayEventCollector()
    let request = GatewayStartRunRequest(
      runID: AgentRunID(),
      modelID: GatewayTestInferenceProvider().modelID,
      initialMessages: [Message(role: .user, content: [.text("hello")])],
      toolChoice: .none
    )

    do {
      try await driver.run(request) { record in
        await collector.append(record)
      }
      Issue.record("Expected corrupt personality data to fail before runtime start.")
    } catch let error as PersonalityProfileStoreError {
      #expect(error == .malformedProfile)
    }

    #expect(await collector.records().isEmpty)
    let persistedRecords = try await journal.records(for: request.runID, after: nil, limit: 128)
    #expect(persistedRecords.isEmpty)
    try await journal.close()
  }

  private static func messageText(_ message: Message) -> String {
    message.content.compactMap { content in
      guard case .text(let text) = content else {
        return nil
      }
      return text
    }.joined(separator: "\n")
  }

  private static func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hex-gateway-personality-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    return directory
  }
}
