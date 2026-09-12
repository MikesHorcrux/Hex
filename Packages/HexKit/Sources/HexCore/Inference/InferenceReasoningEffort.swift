/// A provider-neutral per-request reasoning budget.
///
/// A missing value in ``InferenceOptions`` means the provider should use its configured default.
public enum InferenceReasoningEffort: String, Codable, CaseIterable, Sendable {
  case none
  case minimal
  case low
  case medium
  case high
  case xhigh
  case max
  case ultra
  case persistent
}
