import HexCore
import HexPersonality

enum PersonalMemoryToolAuthorization {
  static func resource(for scope: PersonalMemoryScope) -> String {
    "profile-scope:\(scope.rawValue)"
  }

  static func authorizationDetails(
    scope: PersonalMemoryScope,
    kind: PersonalMemoryKind?,
    limit: Int
  ) -> [String: JSONValue] {
    var details: [String: JSONValue] = [
      "scope": .string(scope.rawValue),
      "limit": .integer(Int64(limit)),
    ]
    if let kind {
      details["kind"] = .string(kind.rawValue)
    }
    return details
  }

}
