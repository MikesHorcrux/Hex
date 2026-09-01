public enum PersonalMemoryStoreError: Error, Equatable, Sendable {
  case invalidConfiguration
  case invalidQuery
  case capacityExceeded
  case byteLimitExceeded
  case staleUpdate
  case serializationFailed
}
