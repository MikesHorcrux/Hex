@MainActor
protocol AgentComposerPreferenceStoring: AnyObject {
  func selectedModelID() -> String?
  func selectedEffort() -> AgentComposerEffort
  func saveSelectedModelID(_ modelID: String?)
  func saveSelectedEffort(_ effort: AgentComposerEffort)
}
