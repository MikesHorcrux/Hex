import Foundation

public struct ProcessSessionPage: Codable, Equatable, Sendable {
  public let session: ProcessSessionRecord
  public let data: Data
  public let offset: Int64
  public let nextOffset: Int64
  public let durableThrough: Int64
  public init(session: ProcessSessionRecord, data: Data, offset: Int64, durableThrough: Int64) {
    self.session = session
    self.data = data
    self.offset = offset
    nextOffset = offset + Int64(data.count)
    self.durableThrough = durableThrough
  }
}
