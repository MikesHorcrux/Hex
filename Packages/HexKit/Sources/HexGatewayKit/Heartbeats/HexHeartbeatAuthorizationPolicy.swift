import HexCapabilities
import HexCore

/// Applied only after the authorization center has checked Full Access and exact grants. Scheduled
/// runs wait in the resident approval inbox. Human waiting time does not consume execution time.
public actor HexHeartbeatAuthorizationPolicy: AuthorizationPrompting {
  public enum PolicyError: Error, Equatable, Sendable {
    case registrationUnavailable
  }

  private struct Registration {
    let startedAt = ContinuousClock.now
    var waitingSince: ContinuousClock.Instant?
    var completedWait: Duration = .zero
    var observerReleased = false
    var runtimeEnded = false
  }

  private let interactivePrompter: any AuthorizationPrompting
  private var registrations: [AgentRunID: Registration] = [:]

  public init(interactivePrompter: any AuthorizationPrompting) {
    self.interactivePrompter = interactivePrompter
  }

  func register(_ runID: AgentRunID) throws {
    try Task.checkCancellation()
    // Lost admission acknowledgements may leave a conservative tombstone until the runtime exits.
    // Bound those explicitly rather than allowing unlimited retention or guessing that work stopped.
    guard registrations[runID] == nil, registrations.count < 16 else {
      throw PolicyError.registrationUnavailable
    }
    registrations[runID] = Registration()
  }

  func release(_ runID: AgentRunID, confirmedNotAdmitted: Bool = false) {
    guard var registration = registrations[runID] else { return }
    if confirmedNotAdmitted || registration.runtimeEnded {
      registrations.removeValue(forKey: runID)
    } else {
      registration.observerReleased = true
      registrations[runID] = registration
    }
  }

  func runtimeDidEnd(_ runID: AgentRunID) {
    guard var registration = registrations[runID] else { return }
    if registration.observerReleased {
      registrations.removeValue(forKey: runID)
    } else {
      registration.runtimeEnded = true
      registrations[runID] = registration
    }
  }

  func executionTime(for runID: AgentRunID) -> Duration {
    guard let registration = registrations[runID] else { return .zero }
    let now = ContinuousClock.now
    let currentWait = registration.waitingSince.map { $0.duration(to: now) } ?? .zero
    return max(
      .zero, registration.startedAt.duration(to: now) - registration.completedWait - currentWait)
  }

  var registrationCount: Int { registrations.count }

  public func requestDecision(for request: AuthorizationRequest) async throws
    -> AuthorizationPromptResponse
  {
    try Task.checkCancellation()
    if var registration = registrations[request.runID] {
      registration.waitingSince = .now
      registrations[request.runID] = registration
    }
    defer { finishWaiting(for: request.runID) }
    return try await interactivePrompter.requestDecision(for: request)
  }

  private func finishWaiting(for runID: AgentRunID) {
    guard var registration = registrations[runID], let started = registration.waitingSince else {
      return
    }
    registration.completedWait += started.duration(to: .now)
    registration.waitingSince = nil
    registrations[runID] = registration
  }
}
