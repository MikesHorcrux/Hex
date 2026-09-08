import Foundation
import HexCore

/// Host-owned allowlist for built-in, scoped local observation. Never classify from descriptions,
/// model arguments or MCP read-only hints. MCP authorization uses namespaced mcp_* capabilities
/// with operation "call", so it cannot collide with these built-in capability/operation pairs.
enum LowRiskAuthorizationPolicy {
  static func automaticallyAllows(_ request: AuthorizationRequest) -> Bool {
    guard request.toolCallID != nil, let resource = request.resource,
      !resource.isEmpty,
      resource.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F })
    else { return false }
    switch (request.capability.rawValue, request.operation) {
    case ("workspace.read", "read"), ("workspace.read", "list"), ("workspace.read", "search"):
      // WorkspaceFileSystem constructs this resource only after root-relative path validation,
      // and revalidates descriptor/path ownership during execution. This does not grant a new root.
      return resource.hasPrefix("/")
        && !resource.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    case ("personal.memory.read", "list"), ("personal.memory.read", "search"):
      guard case .string(let scope) = request.details["scope"], !scope.isEmpty else { return false }
      return resource == "profile-scope:\(scope)"
    case ("artifact.read", "list"):
      return resource == "conversation-output-catalog:\(request.runID.rawValue.uuidString)"
    case ("artifact.read", "read"), ("artifact.read", "search"):
      guard case .string(let id) = request.details["artifact_id"], UUID(uuidString: id) != nil,
        case .string(let digest) = request.details["sha256"], digest.utf8.count == 64,
        digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
      else { return false }
      return resource == "artifact:\(id):sha256:\(digest)"
    case ("mac.application.read", "list-running-applications"):
      return resource == "mac:running-applications"
    default:
      // Commands, writes, external requests, browser/Mac control, sensitive screen observation,
      // and every unknown integration still require ordinary explicit grants or an approval.
      return false
    }
  }
}
