import Dispatch
import HexCore

struct ProcessAuthorizationLedgerSnapshot: Sendable {
  let request: ProcessExecutionRequest
  let identity: ProcessExecutionIdentity
  let storageBytes: Int
  let expiresAt: UInt64
}
