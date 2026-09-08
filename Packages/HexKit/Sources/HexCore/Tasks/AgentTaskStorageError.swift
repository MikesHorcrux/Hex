public enum AgentTaskStorageError: Error, Sendable {
  case invalidRecord, revisionConflict, unavailable
}
