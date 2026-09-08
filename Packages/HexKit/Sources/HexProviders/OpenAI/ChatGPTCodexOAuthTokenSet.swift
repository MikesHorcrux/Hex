import Foundation

/// Codable token bundle stored as one atomic Keychain value.
struct ChatGPTCodexOAuthTokenSet: Codable, Equatable, Sendable {
  let accessToken: String
  let refreshToken: String
  let idToken: String?
  let expiresAt: Date
  let accountID: String
}
