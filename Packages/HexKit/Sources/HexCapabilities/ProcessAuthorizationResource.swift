import CryptoKit
import Foundation

enum ProcessAuthorizationResource {
  static func resource(
    for request: ProcessExecutionRequest,
    key: SymmetricKey
  ) -> String {
    let values =
      [
        request.executable.path,
        request.workingDirectory.path,
        String(request.timeoutSeconds),
      ] + request.arguments
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
