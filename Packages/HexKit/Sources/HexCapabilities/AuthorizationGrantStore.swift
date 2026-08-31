/// Durable storage for exact persistent grants. A successful `insert` is the persistence commit
/// point; implementations must not report success before the grant is durable.
public protocol AuthorizationGrantStore: Sendable {
  func contains(_ key: AuthorizationGrantKey) async throws -> Bool
  func insert(_ key: AuthorizationGrantKey) async throws
  func remove(_ key: AuthorizationGrantKey) async throws
  func removeAll() async throws
}
