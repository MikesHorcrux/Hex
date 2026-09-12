import Foundation

public struct ProcessSessionCommand: Codable, Equatable, Sendable {
  public let sessionID: UUID
  public let operationID: String
  public let expectedSequence: Int64
  public let originTaskID: UUID?
  public let action: ProcessSessionCommandAction
  public let data: Data
  public let columns: UInt16
  public let rows: UInt16

  public init(
    sessionID: UUID, operationID: String, expectedSequence: Int64,
    action: ProcessSessionCommandAction, data: Data = Data(), columns: UInt16 = 120,
    rows: UInt16 = 30,
    originTaskID: UUID? = nil
  ) {
    self.sessionID = sessionID
    self.operationID = operationID
    self.expectedSequence = expectedSequence
    self.originTaskID = originTaskID
    self.action = action
    self.data = data
    self.columns = columns
    self.rows = rows
  }
}
