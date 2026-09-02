import Foundation
import Testing

@testable import HexProviders

@Suite("ChatGPT Codex OAuth transport")
struct URLSessionChatGPTCodexOAuthTransportTests {
  @Test
  func decodesStringPollingIntervalReturnedByOpenAI() throws {
    let receivedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let data = Data(
      #"{"device_auth_id":"device-test","user_code":"ABCD-EFGH","interval":"5","expires_at":"2033-05-18T03:33:20.000000+00:00"}"#
        .utf8
    )

    let challenge =
      try URLSessionChatGPTCodexOAuthTransport
      .decodeDeviceAuthorizationChallenge(data, receivedAt: receivedAt)

    #expect(challenge.deviceAuthorizationID == "device-test")
    #expect(challenge.userCode == "ABCD-EFGH")
    #expect(challenge.pollInterval == 5)
    #expect(challenge.expiresAt == receivedAt.addingTimeInterval(15 * 60))
  }
}
