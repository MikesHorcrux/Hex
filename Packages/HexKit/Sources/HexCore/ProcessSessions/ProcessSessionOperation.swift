import Foundation

public struct ProcessSessionOperation: Codable, Equatable, Sendable {
  public let id: String
  public let sessionID: UUID
  public let digest: Data
  public let sequence: Int64
  public let action: String
  public var state: String
  public var acceptedBytes: Int = 0
  public init(
    id: String, sessionID: UUID, digest: Data, sequence: Int64,
    action: String, state: String = "pending"
  ) {
    self.id = id
    self.sessionID = sessionID
    self.digest = digest
    self.sequence = sequence
    self.action = action
    self.state = state
  }
}
