import Foundation

public struct GitWorkspaceSnapshot: Codable, Equatable, Sendable {
  public let repository: String
  public let head: String
  public let status: Data
  public let stagedDiff: String
  public let unstagedDiff: String
  public let untracked: [String: String]
  public let capturedAt: Date
  public let previewTruncated: Bool
  public init(
    repository: String, head: String, status: Data, stagedDiff: String,
    unstagedDiff: String, untracked: [String: String], capturedAt: Date = Date(),
    previewTruncated: Bool = false
  ) {
    self.repository = repository
    self.head = head
    self.status = status
    self.stagedDiff = stagedDiff
    self.unstagedDiff = unstagedDiff
    self.untracked = untracked
    self.capturedAt = capturedAt
    self.previewTruncated = previewTruncated
  }
}
