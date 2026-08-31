/// Process-memory storage for tests, previews, and explicitly non-durable sessions.
public actor VolatileAuthorizationGrantStore: AuthorizationGrantStore {
  private var grants: Set<AuthorizationGrantKey>

  public init(grants: Set<AuthorizationGrantKey> = []) {
    self.grants = grants
  }

  public func contains(_ key: AuthorizationGrantKey) -> Bool {
    grants.contains(key)
  }

  public func insert(_ key: AuthorizationGrantKey) {
    grants.insert(key)
  }

  public func remove(_ key: AuthorizationGrantKey) {
    grants.remove(key)
  }

  public func removeAll() {
    grants.removeAll()
  }
}
