public struct Message: Identifiable, Codable, Equatable, Sendable {
  public let id: MessageID
  public let role: MessageRole
  public let content: [MessageContent]

  public init(
    id: MessageID = MessageID(),
    role: MessageRole,
    content: [MessageContent]
  ) {
    self.id = id
    self.role = role
    self.content = content
  }
}
