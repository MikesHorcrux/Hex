public enum PersonalityProfileError: Error, Equatable, Sendable {
  case invalidName
  case invalidIdentity
  case invalidVoice
  case invalidCollection
  case duplicateCollectionValue
  case profileTooLarge
}
