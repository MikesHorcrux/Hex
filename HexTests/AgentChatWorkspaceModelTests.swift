import Foundation
import HexCore
import HexIPC
import Testing

@testable import Hex

@MainActor
@Suite("Conversation message delivery")
struct AgentChatWorkspaceModelTests {
  @Test
  func lostAdmissionReplyKeepsTheSameConversationAndMessage() async throws {
    let client = PreviewHexAgentClient()
    let transport = LostReplyClient()
    let storage = EmptyStorage()
    let model = AgentChatWorkspaceModel(client: client, taskClient: transport, storage: storage)
    let workspace = AgentWorkspaceModel(client: client)
    await workspace.connect()
    model.draft = "  Remember COBALT-42 \n"
    let parent = model.newID
    await model.send(workspace: workspace)
    #expect(model.pending?.conversationID == parent)
    #expect(model.draft == "  Remember COBALT-42 \n")
    await model.send(workspace: workspace)
    #expect(model.pending == nil)
    #expect(model.selectedID == parent)
    #expect(model.draft.isEmpty)
    let submissions = await transport.submissions
    #expect(submissions.count == 2)
    #expect(submissions.first == submissions.last)
    #expect(await transport.created == 1)
  }

  @Test
  func failedImportPreventsAdmissionAndCanRecoverAfterReconnect() async throws {
    let client = PreviewHexAgentClient()
    let transport = LostReplyClient()
    let model = AgentChatWorkspaceModel(
      client: client, taskClient: transport, storage: EmptyStorage())
    let archive = RecoveringArchive()
    let workspace = AgentWorkspaceModel(client: client, conversationStore: archive)
    await workspace.connect()
    model.draft = "Keep my old conversations"
    await model.send(workspace: workspace)
    #expect(!model.storageReady)
    #expect(await transport.submissions.isEmpty)
    #expect(model.draft == "Keep my old conversations")
    await archive.allowLoad()
    await model.prepareHistory(workspace: workspace)
    #expect(model.storageReady)
    #expect(workspace.didRestoreConversations)
    #expect(model.error == nil)
  }

  @Test
  func switchingConversationsKeepsDraftsSeparate() {
    let client = PreviewHexAgentClient()
    let model = AgentChatWorkspaceModel(
      client: client, taskClient: LostReplyClient(), storage: EmptyStorage())
    let first = UUID()
    let second = UUID()
    model.selectedID = first
    model.draft = "First draft"
    model.selectedID = second
    model.draft = "Second draft"
    model.selectedID = first
    #expect(model.draft == "First draft")
    model.selectedID = second
    #expect(model.draft == "Second draft")
  }

  @Test
  func rejectedMessageRetainsAnEditableDraft() async throws {
    let client = PreviewHexAgentClient()
    let model = AgentChatWorkspaceModel(
      client: client, taskClient: RejectingClient(), storage: EmptyStorage())
    let workspace = AgentWorkspaceModel(client: client)
    await workspace.connect()
    model.draft = "An instruction the service rejects"
    await model.send(workspace: workspace)
    #expect(model.pending == nil)
    #expect(model.draft == "An instruction the service rejects")
    #expect(model.error == "Rejected before admission")
  }

  @Test
  func refreshKeepsVisibleHistoryUntilTheLegacyPageIsReady() async throws {
    let id = UUID()
    let visible = ConversationItem(role: .assistant, text: "Already visible")
    let final = ConversationItem(role: .assistant, text: "Complete page")
    let storage = HeldHistoryStorage(
      id: id,
      entry: .init(
        id: "display:\(final.id)", kind: .display,
        payload: try JSONEncoder().encode(final)))
    let model = AgentChatWorkspaceModel(
      client: PreviewHexAgentClient(), taskClient: LostReplyClient(), storage: storage)
    model.selectedID = id
    model.items = [visible]
    let loading = Task { try await model.loadTimeline(id, before: nil, token: model.generation) }
    for _ in 0..<200 {
      if await storage.entered { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await storage.entered)
    #expect(model.items == [visible])
    await storage.release()
    try await loading.value
    #expect(model.items == [final])
  }

  private actor HeldHistoryStorage: ConversationStorage {
    let id: UUID
    let entry: ConversationStorageRequest.Entry
    var entered = false
    var waiter: CheckedContinuation<Void, Never>?
    init(id: UUID, entry: ConversationStorageRequest.Entry) {
      self.id = id
      self.entry = entry
    }
    func release() {
      waiter?.resume()
      waiter = nil
    }
    func conversationStorage(_ request: ConversationStorageRequest) async
      -> ConversationStorageRequest.Response
    {
      var response = ConversationStorageRequest.Response()
      switch request {
      case .read:
        response.documents = [
          .init(id: id, title: "Legacy", createdAt: Date(), updatedAt: Date(), state: Data())
        ]
      case .entries:
        entered = true
        await withCheckedContinuation { waiter = $0 }
        response.entries = [entry]
      default: break
      }
      return response
    }
  }

  private actor RejectingClient: HexGatewayTaskClient {
    func taskOperation(_ request: GatewayTaskRequest) throws -> GatewayTaskRequest.Response {
      if case .submitConversation = request {
        throw GatewayFailure(code: .taskRequestRejected, message: "Rejected before admission")
      }
      return .init()
    }
  }

  private actor LostReplyClient: HexGatewayTaskClient {
    var submissions: [GatewayTaskRequest] = []
    var record: AgentTaskRecord?
    var created = 0
    func taskOperation(_ request: GatewayTaskRequest) throws -> GatewayTaskRequest.Response {
      switch request {
      case .submitConversation(let id, let parent, let previous, let title, _):
        submissions.append(request)
        if record == nil {
          created += 1
          var value = AgentTaskRecord(id: id, title: title, request: Data(), admissionHash: Data())
          value.conversationID = parent
          value.predecessorID = previous
          value.phase = .completed
          record = value
          throw GatewayFailure(code: .transportUnavailable, message: "Lost committed reply")
        }
        return .init(tasks: record.map { [$0] } ?? [])
      case .conversationTasks: return .init(tasks: record.map { [$0] } ?? [])
      default: return .init()
      }
    }
  }
  private actor EmptyStorage: ConversationStorage {
    func conversationStorage(_ request: ConversationStorageRequest)
      -> ConversationStorageRequest.Response
    { .init() }
  }

  private actor RecoveringArchive: AgentConversationStoring {
    var ready = false
    func allowLoad() { ready = true }
    func load() throws -> AgentConversationArchive? {
      guard ready else {
        throw GatewayFailure(code: .transportUnavailable, message: "Disconnected")
      }
      return nil
    }
    func save(_ archive: AgentConversationArchive) {}
    nonisolated func validateForPersistence(_ archive: AgentConversationArchive) {}
  }
}
