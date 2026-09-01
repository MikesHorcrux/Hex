import CryptoKit
import Foundation

enum ProcessAuthorizationResource {
  static func resource(
    for request: ProcessExecutionRequest,
    identity: ProcessExecutionIdentity,
    key: SymmetricKey
  ) -> String {
    var values = [
      request.executable.path,
      request.workingDirectory.path,
      String(request.timeoutSeconds),
      String(request.arguments.count),
    ]
    values.append(contentsOf: request.arguments)
    values.append(String(request.environment.count))
    for (name, value) in request.environment.sorted(by: { $0.key < $1.key }) {
      values.append(name)
      values.append(value)
    }
    values.append(contentsOf: identity.canonicalValues)
    var canonical = ""
    for value in values {
      canonical += "\(value.utf8.count):\(value)"
    }
    let digest = HMAC<SHA256>.authenticationCode(
      for: Data(canonical.utf8),
      using: key
    )
    .map { String(format: "%02x", $0) }
    .joined()
    return "process:hmac-sha256:\(digest)"
  }
}
