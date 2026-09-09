import Foundation

public struct ProcessSessionRecord: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let scope: ProcessSessionScope
  public let runID: AgentRunID
  public let callID: ToolCallID
  public let epoch: UUID
  public let executable: String
  public let arguments: [String]
  public let transport: String
  public let retained: Bool
  public let deadline: Date
  public var phase: String = "preparing"
  public var revision: Int64 = 0
  public var inputSequence: Int64 = 0
  public var outputBytes: Int64 = 0
  public var editGeneration: Int64 = 0
  public var reconciliationID: UUID?
  public var exitCode: Int32?
  public var signal: Int32?
  public var cleanupConfirmed = false
  public var explanation = ""
  public var createdAt = Date()
  public var terminal: Bool { phase == "exited" || phase == "interrupted" || phase == "blocked" }
  public init(
    id: UUID = UUID(), scope: ProcessSessionScope, runID: AgentRunID,
    callID: ToolCallID, epoch: UUID, executable: String, arguments: [String],
    transport: String, retained: Bool, deadline: Date
  ) {
    self.id = id
    self.scope = scope
    self.runID = runID
    self.callID = callID
    self.epoch = epoch
    self.executable = executable
    self.arguments = arguments
    self.transport = transport
    self.retained = retained
    self.deadline = deadline
  }
}
