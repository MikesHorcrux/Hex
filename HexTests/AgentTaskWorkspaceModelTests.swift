import Foundation
import HexCore
import HexIPC
import Testing

@testable import Hex

@MainActor
@Suite("Durable task workspace delivery")
struct AgentTaskWorkspaceModelTests {
  @Test
  func uncertainControlReplyRetriesTheSameOperation() async throws {
    let transport = LostReplyTaskClient()
    let record = await transport.record
    let model = AgentTaskWorkspaceModel(client: PreviewHexAgentClient(), taskClient: transport)
    model.tasks = [record]
    model.selectedID = record.id
    await model.control(.steer("continue once"))
    #expect(model.error != nil)
    await model.control(.steer("continue once"))
    #expect(model.error == nil)
    let ids = await transport.operationIDs
    #expect(ids.count == 2)
    #expect(Set(ids).count == 1)
    #expect(await transport.appliedCount == 1)
  }

  private actor LostReplyTaskClient: HexGatewayTaskClient {
    var record = AgentTaskRecord(
      id: UUID(), title: "fixture", request: Data(), admissionHash: Data())
    var operationIDs: [UUID] = []
    var appliedCount = 0
    func taskOperation(_ request: GatewayTaskRequest) throws -> GatewayTaskRequest.Response {
      switch request {
      case .control(_, _, let id, _):
        operationIDs.append(id)
        if record.lastControlID != id {
          appliedCount += 1
          record.lastControlID = id
          record.revision += 1
          throw GatewayFailure(code: .transportUnavailable, message: "Reply lost after commit")
        }
        return .init(tasks: [record.summary])
      default: return .init(tasks: [record.summary])
      }
    }
  }
}
