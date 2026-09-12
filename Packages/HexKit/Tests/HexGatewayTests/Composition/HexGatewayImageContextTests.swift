import Foundation
import HexCore
import HexGatewayKit
import HexIPC
import HexPersistence
import Testing

@Suite("Gateway screenshot context")
struct HexGatewayImageContextTests {
  @Test(arguments: ["gpt-5.6-luna", "unknown-model"])
  func screenshotReceiptPreservesMediaAndContinuesOnlyWithAKnownBound(modelID: String) async throws
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = try await SQLiteAgentEventJournal.open(
      configuration: .init(databaseURL: root.appendingPathComponent("journal.sqlite")))
    // A long transport representation exercises the production failure independently of image
    // decoding, which belongs to the provider. No file is read and no network request is made.
    let image = ImageContent(
      sourceURL: try #require(
        URL(string: "data:image/png;base64," + String(repeating: "A", count: 1_280_000))),
      mediaType: "image/png")
    let provider = ImageProvider(modelID: ModelID(rawValue: modelID))
    let driver = HexGatewayRunDriverAdapter(
      inferenceProvider: provider, toolExecutor: ImageTool(image: image),
      authorizationProvider: GatewayTestAuthorizationProvider(), journal: journal)
    let runID = AgentRunID()
    let request = GatewayStartRunRequest(
      runID: runID, modelID: provider.modelID,
      initialMessages: [.init(role: .user, content: [.text("Inspect the page")])])
    if modelID == "unknown-model" {
      await #expect(throws: GatewayFailure.self) { try await driver.run(request, emit: { _ in }) }
      #expect(await provider.requests.count == 1)
    } else {
      try await driver.run(request, emit: { _ in })
      let requests = await provider.requests
      #expect(requests.count == 2)
      let result = requests.last?.messages.flatMap(\.content).compactMap { content -> ToolResult? in
        if case .toolResult(let result) = content { return result }
        return nil
      }.first
      #expect(result?.content == [.image(image)])
    }
    let records = try await journal.records(for: runID, after: nil, limit: 128)
    let saved = records.compactMap { record -> ToolResult? in
      if case .toolFinished(let result) = record.event { return result }
      return nil
    }.first
    #expect(saved?.content == [.image(image)])
    try await journal.close()
  }

  private actor ImageProvider: InferenceProvider {
    nonisolated let modelID: ModelID
    nonisolated let descriptor = ProviderDescriptor(
      id: .init(rawValue: "openai"), displayName: "Fixture",
      capabilities: [.textInput, .imageInput, .toolCalling, .streaming])
    var requests: [InferenceRequest] = []
    init(modelID: ModelID) { self.modelID = modelID }
    func availableModels() async throws -> [ModelDescriptor] {
      [
        .init(
          id: modelID, providerID: descriptor.id, displayName: "Fixture",
          capabilities: descriptor.capabilities, contextWindow: 280_000, maxOutputTokens: 256)
      ]
    }
    func stream(_ request: InferenceRequest) async throws -> InferenceStream {
      requests.append(request)
      let first = requests.count == 1
      return InferenceStream(
        events: AsyncThrowingStream { continuation in
          continuation.yield(.started(providerResponseID: UUID().uuidString))
          if first {
            continuation.yield(.toolCall(.init(name: "capture", arguments: [:])))
            continuation.yield(.completed(.toolCalls))
          } else {
            continuation.yield(.textDelta("Page inspected"))
            continuation.yield(.completed(.stop))
          }
          continuation.finish()
        }, onCancellation: {}, waitForTermination: {})
    }
  }

  private struct ImageTool: ToolExecutor {
    let image: ImageContent
    func availableTools() async throws -> [ToolDefinition] {
      [
        .init(
          name: "capture", description: "Capture a fixture",
          inputSchema: ["type": .string("object")])
      ]
    }
    func execute(_ call: ToolCall, in context: ToolExecutionContext) async throws -> ToolResult {
      .init(toolCallID: call.id, status: .success, output: .null, content: [.image(image)])
    }
  }
}
