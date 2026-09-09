public enum WorkspacePatchError: String, Error, Sendable {
  case invalidPatch, unavailable, priorOutcomeUncertain, capacity, reviewIncomplete
}
