import HexCapabilities
import HexCore

/// Applied only after the authorization center has checked Full Access and exact grants. Scheduled
/// runs must stop on an actual missing grant, not create an interactive waiter nobody can answer.
public actor HexHeartbeatAuthorizationPolicy: AuthorizationPrompting {
  public enum PolicyError: Error, Equatable, Sendable {
    case registrationUnavailable
    case interactiveAuthorizationRequired
  }

  private struct Registration {
    var authorizationRequired = false
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

  func requiresInteractiveAuthorization(for runID: AgentRunID) -> Bool {
    registrations[runID]?.authorizationRequired == true
  }

  var registrationCount: Int { registrations.count }

  public func requestDecision(for request: AuthorizationRequest) async throws
    -> AuthorizationPromptResponse
  {
    try Task.checkCancellation()
    if var registration = registrations[request.runID] {
      registration.authorizationRequired = true
      registrations[request.runID] = registration
      throw PolicyError.interactiveAuthorizationRequired
    }
    return try await interactivePrompter.requestDecision(for: request)
  }
}
