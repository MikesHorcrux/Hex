public enum PersonalMemorySource: String, Codable, CaseIterable, Sendable {
  case explicitUserStatement
  case explicitUserCorrection
  case userApprovedSuggestion
}
