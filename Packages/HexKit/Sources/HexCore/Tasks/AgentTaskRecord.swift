import Foundation

/// A durable unit of user work. Run IDs identify attempts; they are never reused for continuation.
public struct AgentTaskRecord: Codable, Equatable, Sendable, Identifiable {
  public enum Phase: String, Codable, Sendable {
    case queued, running, pausing, cancelling, paused, waiting, blocked, completed, cancelled
    public var isTerminal: Bool { self == .completed || self == .cancelled }
  }
  public struct Instruction: Codable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public init(id: UUID, text: String) {
      self.id = id
      self.text = text
    }
  }
  public let id: UUID
  /// Stable parent conversation; nil is decoded only from pre-conversation task records.
  public var conversationID: UUID?
  public var predecessorID: UUID?
  public var userMessage: Message?
  public let title: String
  public let createdAt: Date
  public var updatedAt: Date
  public var revision: Int64
  public var phase: Phase
  public var runID: AgentRunID?
  public var attemptCount: Int
  public var attemptPending: Bool = false
  public var lastControlID: UUID?
  public var lastControlHash: Data?
  public var reconciliation: String?
  public var retryCount: Int
  public var notBefore: Date?
  public var explanation: String
  public var instructions: [Instruction]
  /// Versioned gateway request, owned by the resident. Omitted from UI responses.
  public var request: Data
  /// Immutable admission identity, independent of a later continuation request.
  public let admissionHash: Data

  public init(id: UUID, title: String, request: Data, admissionHash: Data, now: Date = Date()) {
    self.id = id
    self.title = title
    self.request = request
    self.admissionHash = admissionHash
    createdAt = now
    updatedAt = now
    revision = 0
    phase = .queued
    attemptCount = 0
    retryCount = 0
    explanation = "Queued"
    instructions = []
  }

  public var summary: Self {
    var copy = self
    copy.request = Data()
    copy.userMessage = nil
    copy.instructions = []
    copy.reconciliation = nil
    return copy
  }
}
