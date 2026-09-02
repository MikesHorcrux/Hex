import Foundation
import HexPersonality
import Observation

@MainActor
@Observable
final class HexPersonalityProfileModel {
  var name = "" {
    didSet {
      let bounded = HexPersonalityInputLimits.bounded(
        name,
        maximumBytes: HexPersonalityInputLimits.profileNameBytes
      )
      if name != bounded {
        name = bounded
      }
    }
  }

  var identity = "" {
    didSet {
      let bounded = HexPersonalityInputLimits.bounded(
        identity,
        maximumBytes: HexPersonalityInputLimits.profileTextBytes
      )
      if identity != bounded {
        identity = bounded
      }
    }
  }

  var voice = "" {
    didSet {
      let bounded = HexPersonalityInputLimits.bounded(
        voice,
        maximumBytes: HexPersonalityInputLimits.profileTextBytes
      )
      if voice != bounded {
        voice = bounded
      }
    }
  }

  var traitsText = "" {
    didSet {
      let bounded = HexPersonalityInputLimits.boundedCollectionText(traitsText)
      if traitsText != bounded {
        traitsText = bounded
      }
    }
  }

  var valuesText = "" {
    didSet {
      let bounded = HexPersonalityInputLimits.boundedCollectionText(valuesText)
      if valuesText != bounded {
        valuesText = bounded
      }
    }
  }

  var boundariesText = "" {
    didSet {
      let bounded = HexPersonalityInputLimits.boundedCollectionText(boundariesText)
      if boundariesText != bounded {
        boundariesText = bounded
      }
    }
  }

  private(set) var state = HexPersonalityProfileState.idle
  private(set) var isLoading = false
  private(set) var isSaving = false
  private(set) var statusMessage: String?
  private(set) var errorMessage: String?

  private let service: any HexPersonalityServicing
  private var hasLoaded = false

  init(service: any HexPersonalityServicing = HexUnavailablePersonalityService()) {
    self.service = service
  }

  var canEdit: Bool {
    hasLoaded && !isLoading && !isSaving && !state.isUnavailable
  }

  var canSave: Bool {
    canEdit
  }

  func load() async {
    guard !hasLoaded, !isLoading else {
      return
    }
    await performLoad()
  }

  func reload() async {
    guard !isLoading else {
      return
    }
    hasLoaded = false
    await performLoad()
  }

  func save() async {
    guard !isSaving else {
      return
    }
    guard hasLoaded, !isLoading, !state.isUnavailable else {
      errorMessage =
        state.isUnavailable
        ? "Personality profile editing is unavailable in this build."
        : "Wait for the personality profile to finish loading before saving."
      return
    }

    let profile: PersonalityProfile
    do {
      profile = try makeProfile()
    } catch {
      errorMessage = Self.validationMessage(for: error)
      statusMessage = nil
      return
    }

    isSaving = true
    errorMessage = nil
    statusMessage = nil
    defer {
      isSaving = false
    }

    do {
      try await service.saveProfile(profile)
      apply(profile)
      state = .loaded
      statusMessage = "Personality profile saved."
      errorMessage = nil
    } catch is CancellationError {
      return
    } catch {
      errorMessage = Self.operationMessage(for: error)
    }
  }

  func dismissMessage() {
    statusMessage = nil
    errorMessage = nil
  }

  private func performLoad() async {
    isLoading = true
    state = .loading
    statusMessage = nil
    errorMessage = nil
    defer {
      isLoading = false
    }

    do {
      guard let profile = try await service.loadProfile() else {
        clearDraft()
        state = .empty
        hasLoaded = true
        return
      }
      apply(profile)
      state = .loaded
      hasLoaded = true
    } catch is CancellationError {
      state = .idle
    } catch {
      state = Self.state(for: error)
      errorMessage = state.message
      hasLoaded = true
    }
  }

  private func makeProfile() throws -> PersonalityProfile {
    try PersonalityProfile(
      name: name,
      identity: identity,
      voice: voice,
      traits: HexPersonalityInputLimits.collectionValues(from: traitsText),
      values: HexPersonalityInputLimits.collectionValues(from: valuesText),
      boundaries: HexPersonalityInputLimits.collectionValues(from: boundariesText)
    )
  }

  private func apply(_ profile: PersonalityProfile) {
    name = profile.name
    identity = profile.identity
    voice = profile.voice
    traitsText = profile.traits.joined(separator: "\n")
    valuesText = profile.values.joined(separator: "\n")
    boundariesText = profile.boundaries.joined(separator: "\n")
  }

  private func clearDraft() {
    name = ""
    identity = ""
    voice = ""
    traitsText = ""
    valuesText = ""
    boundariesText = ""
  }

  private static func state(for error: any Error) -> HexPersonalityProfileState {
    if let error = error as? HexPersonalityServiceError, error == .unavailable {
      return .unavailable(error.localizedDescription)
    }
    if let error = error as? PersonalityProfileStoreError {
      switch error {
      case .malformedProfile:
        return .corrupted(
          "The saved personality profile is corrupted. Review the fields and save a replacement."
        )
      case .invalidFileURL, .invalidMaximumBytes:
        return .unavailable("The personality profile store is unavailable in this build.")
      case .profileTooLarge, .unsafeFile, .lockFailure, .encodingFailure, .ioFailure:
        return .failed("The personality profile could not be loaded. Try again.")
      }
    }
    return .failed("The personality profile could not be loaded. Try again.")
  }

  private static func validationMessage(for error: any Error) -> String {
    guard let error = error as? PersonalityProfileError else {
      return "Check the profile fields and try again."
    }
    return switch error {
    case .invalidName:
      "Enter a name."
    case .invalidIdentity:
      "Enter an identity."
    case .invalidVoice:
      "Enter a voice description."
    case .invalidCollection:
      "Each list entry must be non-empty, unique, and within its limit."
    case .duplicateCollectionValue:
      "List entries must be unique, ignoring case and accents."
    case .profileTooLarge:
      "The profile is too large. Shorten the fields or lists before saving."
    }
  }

  private static func operationMessage(for error: any Error) -> String {
    if let error = error as? HexPersonalityServiceError, error == .unavailable {
      return error.localizedDescription
    }
    if let error = error as? PersonalityProfileStoreError {
      switch error {
      case .profileTooLarge:
        return "The profile is too large to save."
      case .unsafeFile:
        return "The personality profile location is not safe to write."
      case .lockFailure:
        return "The personality profile is busy. Try again."
      case .invalidFileURL, .invalidMaximumBytes, .malformedProfile, .encodingFailure, .ioFailure:
        return "The personality profile could not be saved. Try again."
      }
    }
    return "The personality profile could not be saved. Try again."
  }
}
