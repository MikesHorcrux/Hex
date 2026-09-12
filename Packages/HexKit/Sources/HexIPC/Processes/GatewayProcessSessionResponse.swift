import Foundation
import HexCore

public struct GatewayProcessSessionResponse: Codable, Sendable {
  public var filePreview: WorkspaceFileChangePreview?
  public var review: WorkspaceChangesReview?
  public var sessions: [ProcessSessionRecord] = []
  public var page: ProcessSessionPage?
  public var operation: ProcessSessionOperation?
  public init() {}
}
