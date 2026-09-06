import Foundation
import HexCore
import HexGatewayKit
import HexIPC
import HexPersistence
import Testing

@Suite("Gateway self knowledge")
struct HexGatewaySelfKnowledgeTests {
  @Test
  func everyRunReceivesItsOwnModelAndWorkspaceAndReadOnlySelfTool() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hex-self-knowledge-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = try await SQLiteAgentEventJournal.open(
      configuration: SQLiteAgentEventJournalConfiguration(
        databaseURL: root.appendingPathComponent("journal.sqlite")
      )
    )
    let provider = GatewayTestInferenceProvider(
      toolCall: ToolCall(name: "hex_inspect_self", arguments: [:])
    )
    let driver = HexGatewayRunDriverAdapter(
      inferenceProvider: provider,
      toolExecutor: GatewayTestToolExecutor(),
      authorizationProvider: GatewayTestAuthorizationProvider(),
      journal: journal
    )
    for name in ["first-project", "second-project"] {
      let runID = AgentRunID()
      let workspace = root.appendingPathComponent(name, isDirectory: true)
      try await driver.run(
        GatewayStartRunRequest(
          runID: runID,
          modelID: provider.modelID,
          initialMessages: [Message(role: .user, content: [.text("Where are your files?")])],
          workingDirectory: workspace
        ),
        emit: { _ in }
      )
      let records = try await journal.records(for: runID, after: nil, limit: 128)
      let request = try #require(
        records.compactMap { record -> InferenceRequest? in
          guard case .inferenceRequested(let request) = record.event else { return nil }
          return request
        }.first)
      let context = request.messages.filter { $0.role == .developer }.flatMap(\.content)
        .compactMap { content -> String? in
          guard case .text(let text) = content else { return nil }
          return text
        }.joined(separator: "\n")
      #expect(context.contains("hex_runtime_self"))
      #expect(context.contains(name))
      #expect(context.contains(provider.modelID.rawValue))
      #expect(request.tools.contains { $0.name == "hex_inspect_self" })
      let selfMessage = try #require(
        request.messages.filter { $0.role == .developer }
          .flatMap(\.content).compactMap { content -> String? in
            guard case .text(let text) = content, text.contains("hex_runtime_self") else {
              return nil
            }
            return text
          }.first)
      let jsonLine = try #require(selfMessage.split(separator: "\n").last)
      let promptSnapshot = try JSONDecoder().decode(JSONValue.self, from: Data(jsonLine.utf8))
      let toolResult = try #require(
        records.compactMap { record -> ToolResult? in
          guard case .toolFinished(let result) = record.event else { return nil }
          return result
        }.first)
      #expect(toolResult.status == .success)
      guard case .object(let output) = toolResult.output else {
        Issue.record("Expected structured self-inspection output")
        continue
      }
      #expect(output["runtime"] == promptSnapshot)
      #expect(output["manual"] == .string(HexSelfOperatingManual().text))
    }
    try await journal.close()
  }
}
