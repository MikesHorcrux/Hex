/// Fail-closed default that prevents a UI choice labeled persistent from silently becoming a
/// process-memory grant when durable storage has not been composed.
public struct UnavailableAuthorizationGrantStore: AuthorizationGrantStore, Sendable {
  public init() {}

  public func contains(_ key: AuthorizationGrantKey) throws -> Bool {
    false
  }

  public func insert(_ key: AuthorizationGrantKey) throws {
    throw CapabilityAuthorizationCenterError.persistentStoreUnavailable
  }

  public func remove(_ key: AuthorizationGrantKey) throws {
    throw CapabilityAuthorizationCenterError.persistentStoreUnavailable
  }

  public func removeAll() throws {
    throw CapabilityAuthorizationCenterError.persistentStoreUnavailable
  }
}
