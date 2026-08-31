import Foundation
import HexCore
import Testing

@Suite("Protocol surface")
struct ProtocolSurfaceTests {
  @Test
  func actorImplementationsSatisfyAsyncProtocols() async throws {
    let provider: any InferenceProvider = InferenceProviderStub()
    let authorizationProvider: any AuthorizationProvider = AuthorizationProviderStub()
    let executor: any ToolExecutor = ToolExecutorStub()
    let journal: any AgentEventJournal = AgentEventJournalStub()
    let runID = AgentRunID()
    let inferenceRequest = InferenceRequest(
      providerID: provider.descriptor.id,
      modelID: ModelID(rawValue: "model"),
      messages: []
    )
    let authorizationRequest = AuthorizationRequest(
      runID: runID,
      capability: CapabilityID(rawValue: "test"),
      operation: "inspect",
      explanation: "Exercise the protocol boundary."
    )

    #expect(try await provider.availableModels().count == 1)
    #expect(try await authorizationProvider.authorize(authorizationRequest) == .allow)
    #expect(try await executor.availableTools().count == 1)

    let stream = try await provider.stream(inferenceRequest)
    let events = try await stream.consume { cursor in
      var collected: [InferenceStreamEvent] = []
      while let event = try await cursor.next() {
        collected.append(event)
      }
      return collected
    }
    #expect(events == [.started(providerResponseID: nil), .completed(.stop)])

    let first = try await journal.append(.runStarted, to: runID)
    let second = try await journal.append(.runCompleted, to: runID)
    let records = try await journal.records(for: runID, after: first.sequence, limit: 1)

    #expect(first.sequence == 1)
    #expect(second.sequence == 2)
    #expect(records == [second])
  }

  @Test
  func publicValuesAreSendable() {
    requireSendable(AgentRunID.self)
    requireSendable(JSONValue.self)
    requireSendable(Message.self)
    requireSendable(ProviderDescriptor.self)
    requireSendable(ModelDescriptor.self)
    requireSendable(InferenceRequest.self)
    requireSendable(InferenceStreamEvent.self)
    requireSendable(InferenceStream.self)
    requireSendable(ToolDefinition.self)
    requireSendable(ToolCall.self)
    requireSendable(ToolResult.self)
    requireSendable(AuthorizationRequest.self)
    requireSendable(AuthorizationDecision.self)
    requireSendable(AgentFailure.self)
    requireSendable(AgentEvent.self)
    requireSendable(AgentEventRecord.self)
  }

  @Test
  func moduleMarkerRemainsDependencyFree() {
    #expect(HexCoreModule.dependencies.isEmpty)
  }

  private func requireSendable<Value: Sendable>(_: Value.Type) {}

  actor InferenceProviderStub: InferenceProvider {
    nonisolated let descriptor = ProviderDescriptor(
      id: ProviderID(rawValue: "stub"),
      displayName: "Stub",
      capabilities: [.textInput, .streaming]
    )

    func availableModels() async throws -> [ModelDescriptor] {
      [
        ModelDescriptor(
          id: ModelID(rawValue: "model"),
          providerID: descriptor.id,
          displayName: "Model",
          capabilities: descriptor.capabilities
        )
      ]
    }

    func stream(
      _ request: InferenceRequest
    ) async throws -> InferenceStream {
      let events = AsyncThrowingStream<InferenceStreamEvent, any Error> { continuation in
        continuation.yield(.started(providerResponseID: nil))
        continuation.yield(.completed(.stop))
        continuation.finish()
      }
      return InferenceStream(
        events: events,
        onCancellation: {},
        waitForTermination: {}
      )
    }
  }

  actor AuthorizationProviderStub: AuthorizationProvider {
    func authorize(_ request: AuthorizationRequest) async throws -> AuthorizationDecision {
      .allow
    }
  }

  actor ToolExecutorStub: ToolExecutor {
    func availableTools() async throws -> [ToolDefinition] {
      [ToolDefinition(name: "noop", description: "No operation", inputSchema: [:])]
    }

    func execute(
      _ call: ToolCall,
      in context: ToolExecutionContext
    ) async throws -> ToolResult {
      ToolResult(toolCallID: call.id, status: .success, output: .null)
    }
  }

  actor AgentEventJournalStub: AgentEventJournal {
    private var recordsByRun: [AgentRunID: [AgentEventRecord]] = [:]

    func append(
      _ event: AgentEvent,
      to runID: AgentRunID
    ) async throws -> AgentEventRecord {
      let nextSequence = UInt64(recordsByRun[runID, default: []].count + 1)
      let record = AgentEventRecord(
        id: AgentEventID(),
        runID: runID,
        sequence: nextSequence,
        timestamp: Date(timeIntervalSince1970: TimeInterval(nextSequence)),
        event: event
      )
      recordsByRun[runID, default: []].append(record)
      return record
    }

    func records(
      for runID: AgentRunID,
      after sequence: UInt64?,
      limit: Int
    ) async throws -> [AgentEventRecord] {
      guard limit > 0 else {
        return []
      }
      let minimumSequence = sequence ?? 0
      return Array(
        recordsByRun[runID, default: []]
          .filter { $0.sequence > minimumSequence }
          .prefix(limit)
      )
    }
  }
}
