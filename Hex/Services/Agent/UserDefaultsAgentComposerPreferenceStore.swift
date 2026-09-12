import Foundation

@MainActor
final class UserDefaultsAgentComposerPreferenceStore: AgentComposerPreferenceStoring {
  private static let modelKey = "hex.composer.model.v1"
  private static let effortKey = "hex.composer.effort.v1"

  private let userDefaults: UserDefaults

  init(userDefaults: UserDefaults = .standard) {
    self.userDefaults = userDefaults
  }

  func selectedModelID() -> String? {
    guard let value = userDefaults.string(forKey: Self.modelKey) else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  func selectedEffort() -> AgentComposerEffort {
    guard
      let rawValue = userDefaults.string(forKey: Self.effortKey),
      let effort = AgentComposerEffort(rawValue: rawValue)
    else {
      return .automatic
    }
    return effort
  }

  func saveSelectedModelID(_ modelID: String?) {
    userDefaults.set(modelID, forKey: Self.modelKey)
  }

  func saveSelectedEffort(_ effort: AgentComposerEffort) {
    userDefaults.set(effort.rawValue, forKey: Self.effortKey)
  }
}
