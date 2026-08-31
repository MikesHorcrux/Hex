public enum PersonalityContextComposerError: Error, Equatable, Sendable {
  case invalidConfiguration
  case duplicateMemory
  case contextTooLarge
}
