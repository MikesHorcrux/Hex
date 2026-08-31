public enum GatewayFailureCode: String, Codable, Equatable, Sendable {
  case incompatibleProtocolVersion
  case malformedVersionRange
  case notConnected
  case staleSession
  case capacityExceeded
  case conflictingRunRequest
  case runNotFound
  case replayUnavailable
  case invalidCursor
  case invalidEventSequence
  case wrongRun
  case eventAfterTerminal
  case unsupportedEventSchema
  case producerEndedWithoutTerminalEvent
  case runDriverFailed
  case consumerTooSlow
  case malformedPayload
  case payloadTooLarge
  case disconnected
  case transportUnavailable
}
