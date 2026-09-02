import Foundation
import HexCore

/// Deny-by-default, exact-match authority for one interactive Hex session.
public actor CapabilityAuthorizationCenter: AuthorizationProvider {
  public nonisolated let sessionID: AuthorizationSessionID

  private let prompter: any AuthorizationPrompting
  private let persistentStore: any AuthorizationGrantStore
  private let configuration: CapabilityAuthorizationCenterConfiguration
  private let automaticallyAllowsValidatedRequests: Bool
  private var runGrants: Set<RunAuthorizationGrantKey> = []
  private var sessionGrants: Set<AuthorizationGrantKey> = []

  public init(
    sessionID: AuthorizationSessionID = AuthorizationSessionID(),
    prompter: any AuthorizationPrompting = DenyingAuthorizationPrompter(),
    persistentStore: any AuthorizationGrantStore = UnavailableAuthorizationGrantStore(),
    configuration: CapabilityAuthorizationCenterConfiguration = .standard,
    automaticallyAllowsValidatedRequests: Bool = false
  ) {
    self.sessionID = sessionID
    self.prompter = prompter
    self.persistentStore = persistentStore
    self.configuration = configuration
    self.automaticallyAllowsValidatedRequests = automaticallyAllowsValidatedRequests
  }

  public func authorize(_ request: AuthorizationRequest) async throws -> AuthorizationDecision {
    try Task.checkCancellation()
    try validate(request)
    if automaticallyAllowsValidatedRequests {
      return .allow
    }
    let grantKey = AuthorizationGrantKey(request: request)
    let runGrantKey = RunAuthorizationGrantKey(runID: request.runID, grantKey: grantKey)

    if runGrants.contains(runGrantKey) || sessionGrants.contains(grantKey) {
      return .allow
    }

    if try await persistentStore.contains(grantKey) {
      try Task.checkCancellation()
      return .allow
    }

    try Task.checkCancellation()
    let response = try await prompter.requestDecision(for: request)
    try Task.checkCancellation()

    switch response {
    case .deny(let reason):
      return .deny(reason: sanitizedDenialReason(reason))

    case .allow(.once):
      return .allow

    case .allow(.run):
      guard runGrants.contains(runGrantKey) || runGrants.count < configuration.maximumRunGrants
      else {
        throw CapabilityAuthorizationCenterError.capacityExceeded(
          "The run authorization grant limit was reached."
        )
      }
      runGrants.insert(runGrantKey)
      return .allow

    case .allow(.session):
      guard
        sessionGrants.contains(grantKey)
          || sessionGrants.count < configuration.maximumSessionGrants
      else {
        throw CapabilityAuthorizationCenterError.capacityExceeded(
          "The session authorization grant limit was reached."
        )
      }
      sessionGrants.insert(grantKey)
      return .allow

    case .allow(.persistent):
      try await persistentStore.insert(grantKey)
      return .allow
    }
  }

  public func endRun(_ runID: AgentRunID) async {
    runGrants = runGrants.filter { $0.runID != runID }
  }

  public func revokeSessionGrant(_ key: AuthorizationGrantKey) {
    sessionGrants.remove(key)
  }

  public func revokePersistentGrant(_ key: AuthorizationGrantKey) async throws {
    try await persistentStore.remove(key)
  }

  public func revokeAllPersistentGrants() async throws {
    try await persistentStore.removeAll()
  }

  private func validate(_ request: AuthorizationRequest) throws {
    try validateText(
      request.capability.rawValue,
      field: "capability",
      maximumBytes: configuration.maximumCapabilityBytes,
      rejectsSurroundingWhitespace: true
    )
    try validateText(
      request.operation,
      field: "operation",
      maximumBytes: configuration.maximumOperationBytes,
      rejectsSurroundingWhitespace: true
    )
    if let resource = request.resource {
      try validateText(
        resource,
        field: "resource",
        maximumBytes: configuration.maximumResourceBytes,
        rejectsSurroundingWhitespace: false
      )
    }
    try validateText(
      request.explanation,
      field: "explanation",
      maximumBytes: configuration.maximumExplanationBytes,
      rejectsSurroundingWhitespace: true
    )

    let detailsBytes: Int
    do {
      detailsBytes = try JSONEncoder().encode(request.details).count
    } catch {
      throw CapabilityAuthorizationCenterError.invalidRequest(
        "Authorization details are not serializable."
      )
    }
    guard detailsBytes <= configuration.maximumDetailsBytes else {
      throw CapabilityAuthorizationCenterError.invalidRequest(
        "Authorization details exceed the configured byte limit."
      )
    }
  }

  private func validateText(
    _ value: String,
    field: String,
    maximumBytes: Int,
    rejectsSurroundingWhitespace: Bool
  ) throws {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !rejectsSurroundingWhitespace || trimmed == value else {
      throw CapabilityAuthorizationCenterError.invalidRequest(
        "Authorization \(field) is empty or has invalid surrounding whitespace."
      )
    }
    guard value.utf8.count <= maximumBytes else {
      throw CapabilityAuthorizationCenterError.invalidRequest(
        "Authorization \(field) exceeds the configured byte limit."
      )
    }
  }

  private func sanitizedDenialReason(_ reason: String?) -> String? {
    guard let reason else {
      return nil
    }
    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }
    var result = ""
    var byteCount = 0
    for character in trimmed {
      let fragment = String(character)
      let fragmentByteCount = fragment.utf8.count
      let (nextByteCount, overflowed) = byteCount.addingReportingOverflow(fragmentByteCount)
      guard
        !overflowed,
        nextByteCount <= configuration.maximumExplanationBytes
      else {
        break
      }
      result.append(character)
      byteCount = nextByteCount
    }
    return result.isEmpty ? nil : result
  }
}
