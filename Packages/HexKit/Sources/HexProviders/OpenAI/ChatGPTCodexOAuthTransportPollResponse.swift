import Foundation

struct ChatGPTCodexOAuthTransportPollResponse: Decodable {
  let authorizationCode: String
  let codeVerifier: String

  private enum CodingKeys: String, CodingKey {
    case authorizationCode = "authorization_code"
    case codeVerifier = "code_verifier"
  }
}
