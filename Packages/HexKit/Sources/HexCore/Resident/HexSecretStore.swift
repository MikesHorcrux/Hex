/// Generic secret storage boundary. Implementations must not log or persist secret values outside
/// their protected store, and callers should request a value only immediately before use.
public protocol HexSecretStore: Sendable {
  func secret(for key: HexSecretKey) async throws -> String
  func exists(_ key: HexSecretKey) async throws -> Bool
  func save(_ secret: String, for key: HexSecretKey) async throws
  func delete(_ key: HexSecretKey) async throws
}
