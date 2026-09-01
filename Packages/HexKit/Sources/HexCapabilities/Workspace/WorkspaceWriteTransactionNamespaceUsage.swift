/// A point-in-time snapshot of runtime-slot admission.
public struct WorkspaceWriteTransactionNamespaceUsage: Equatable, Sendable {
  public let claimedSlotCount: Int
  public let unavailableSlotCount: Int
  public let availableSlotCount: Int
  public let maximumSlotCount: Int
}
