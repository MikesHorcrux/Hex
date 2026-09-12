import Foundation
import HexCore

struct LiveProcessSession {
  var record: ProcessSessionRecord
  let connection: ProcessSupervisorConnection
  var tail = Data()
  var lastSeal = Date()
  var pendingOperation: String?
  var flushing = false
}
