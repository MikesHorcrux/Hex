public enum CapabilityAuthorizationCenterError: Error, Equatable, Sendable {
  case invalidRequest(String)
  case capacityExceeded(String)
  case persistentStoreUnavailable
}
