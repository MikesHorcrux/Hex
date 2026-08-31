import HexCore

public struct PersonalityContext: Equatable, Sendable {
  public let policyMessage: Message
  public let dataMessage: Message

  public var messages: [Message] {
    [policyMessage, dataMessage]
  }

  init(policyMessage: Message, dataMessage: Message) {
    self.policyMessage = policyMessage
    self.dataMessage = dataMessage
  }
}
