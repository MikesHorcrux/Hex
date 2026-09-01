import Foundation
import HexCore
import Security

/// Stores Hex resident secrets in the macOS data-protection Keychain.
///
/// The explicit access group is intentionally part of the query so a signed app and its signed
/// resident helper share one item. The app must receive the matching entitlement before this is
/// enabled in a distribution build; no entitlement or secret is placed in a launch plist here.
public actor KeychainHexSecretStore: HexSecretStore {
  public static let defaultService = "com.lunarmothstudios.Hex.resident"
  public static let defaultAccount = "openai-api-key"
  public static let defaultAccessGroup = "5V5PZUN2HG.com.lunarmothstudios.Hex.resident"

  private let service: String
  private let account: String
  private let accessGroup: String

  public init(
    service: String = KeychainHexSecretStore.defaultService,
    account: String = KeychainHexSecretStore.defaultAccount,
    accessGroup: String = KeychainHexSecretStore.defaultAccessGroup
  ) {
    self.service = service
    self.account = account
    self.accessGroup = accessGroup
  }

  public func secret(for key: HexSecretKey) async throws -> String {
    try Task.checkCancellation()
    var query = baseQuery(for: key)
    query[kSecMatchLimit] = kSecMatchLimitOne
    query[kSecReturnData] = true

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status != errSecItemNotFound else {
      throw KeychainHexSecretStoreError.missingSecret
    }
    guard status == errSecSuccess else {
      throw KeychainHexSecretStoreError.keychainFailure(Int32(status))
    }
    guard
      let data = result as? Data,
      let value = String(data: data, encoding: .utf8),
      Self.isPrintableASCII(value)
    else {
      throw KeychainHexSecretStoreError.invalidStoredSecret
    }
    return value
  }

  public func exists(_ key: HexSecretKey) async throws -> Bool {
    try Task.checkCancellation()
    var query = baseQuery(for: key)
    query[kSecMatchLimit] = kSecMatchLimitOne
    query[kSecReturnData] = false
    let status = SecItemCopyMatching(query as CFDictionary, nil)
    if status == errSecSuccess {
      return true
    }
    if status == errSecItemNotFound {
      return false
    }
    throw KeychainHexSecretStoreError.keychainFailure(Int32(status))
  }

  public func save(_ secret: String, for key: HexSecretKey) async throws {
    try Task.checkCancellation()
    guard Self.isPrintableASCII(secret) else {
      throw KeychainHexSecretStoreError.invalidSecret
    }

    let query = baseQuery(for: key)
    // The resident helper may need this value after login while the device is locked, but it must
    // not migrate through backups or another device.
    let attributes: [CFString: Any] = [
      kSecValueData: Data(secret.utf8),
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw KeychainHexSecretStoreError.keychainFailure(Int32(updateStatus))
    }

    var addQuery = query
    addQuery[kSecValueData] = Data(secret.utf8)
    addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    if addStatus == errSecSuccess {
      return
    }
    if addStatus == errSecDuplicateItem {
      let retryStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
      guard retryStatus == errSecSuccess else {
        throw KeychainHexSecretStoreError.keychainFailure(Int32(retryStatus))
      }
      return
    }
    throw KeychainHexSecretStoreError.keychainFailure(Int32(addStatus))
  }

  public func delete(_ key: HexSecretKey) async throws {
    try Task.checkCancellation()
    let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainHexSecretStoreError.keychainFailure(Int32(status))
    }
  }

  /// Convenience OpenAI credential operations for callers that own this concrete store.
  public func apiKey() async throws -> String {
    try await secret(for: .openAIAPIKey)
  }

  public func save(_ apiKey: String) async throws {
    try await save(apiKey, for: .openAIAPIKey)
  }

  public func exists() async throws -> Bool {
    try await exists(.openAIAPIKey)
  }

  public func delete() async throws {
    try await delete(.openAIAPIKey)
  }

  private func baseQuery(for key: HexSecretKey) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account(for: key),
      kSecAttrAccessGroup: accessGroup,
      kSecUseDataProtectionKeychain: true,
    ]
  }

  private func account(for key: HexSecretKey) -> String {
    switch key {
    case .openAIAPIKey:
      account
    }
  }

  private static func isPrintableASCII(_ value: String) -> Bool {
    let bytes = value.utf8
    guard !bytes.isEmpty, bytes.count <= 4_096 else {
      return false
    }
    return bytes.allSatisfy { byte in
      (0x21...0x7E).contains(byte)
    }
  }
}
