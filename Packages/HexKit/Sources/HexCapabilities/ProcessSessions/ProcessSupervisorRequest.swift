import Foundation

struct ProcessSupervisorRequest: Codable, Sendable {
  let executable: String
  let arguments: [String]
  let directory: String
  let environment: [String: String]
  let tty: Bool
  let timeoutSeconds: Int
  let identity: ProcessExecutionIdentity
}
