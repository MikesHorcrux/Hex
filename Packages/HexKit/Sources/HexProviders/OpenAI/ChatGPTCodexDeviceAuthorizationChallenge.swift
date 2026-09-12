import Foundation

/// User-facing data and bounded polling state for one device authorization attempt.
public struct ChatGPTCodexDeviceAuthorizationChallenge: Equatable, Sendable {
  public let userCode: String
  public let verificationURL: URL
  public let deviceAuthorizationID: String
  public let pollInterval: TimeInterval
  public let expiresAt: Date

  public init(
    userCode: String,
    verificationURL: URL,
    deviceAuthorizationID: String,
    pollInterval: TimeInterval,
    expiresAt: Date
  ) {
    self.userCode = userCode
    self.verificationURL = verificationURL
    self.deviceAuthorizationID = deviceAuthorizationID
    self.pollInterval = pollInterval
    self.expiresAt = expiresAt
  }
}
