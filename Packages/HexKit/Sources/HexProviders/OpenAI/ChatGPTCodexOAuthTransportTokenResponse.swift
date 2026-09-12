import Foundation

struct ChatGPTCodexOAuthTransportTokenResponse: Decodable {
  let accessToken: String
  let refreshToken: String?
  let idToken: String?
  let expiresIn: Int?

  private enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
    case idToken = "id_token"
    case expiresIn = "expires_in"
  }
}
