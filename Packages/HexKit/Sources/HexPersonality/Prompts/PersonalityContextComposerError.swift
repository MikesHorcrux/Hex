public enum PersonalityContextComposerError: Error, Equatable, Sendable {
  case invalidConfiguration
  case duplicateMemory
  case scopeMismatch
  case contextTooLarge
}
