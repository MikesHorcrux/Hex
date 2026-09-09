import Foundation

struct ProcessSupervisorMessage: Codable, Sendable {
  var kind: String
  var operation: String? = nil
  var data: Data? = nil
  var count: Int? = nil
  var code: Int32? = nil
  var signal: Int32? = nil
  var columns: UInt16? = nil
  var rows: UInt16? = nil
  var detail: String? = nil
}
