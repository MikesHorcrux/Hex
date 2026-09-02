import Foundation
import HexPersonality
import Testing

@testable import Hex

@Suite("Personality settings models")
struct HexPersonalityModelTests {
  @Test @MainActor
  func profileStartsEmptyAndSavesAnExplicitDraft() async throws {
    let service = FakePersonalityService()
    let model = HexPersonalityProfileModel(service: service)

    await model.load()

    #expect(model.state == .empty)
    #expect(model.canSave)

    model.name = "Hex"
    model.identity = "A personal Mac companion."
    model.voice = "Direct, warm, and precise."
    model.traitsText = "curious\nprotective"
    model.valuesText = "user agency"
    model.boundariesText = "Never pretend an action happened."
    await model.save()

    let saved = try #require(await service.profile)
    let expected = try PersonalityProfile(
      name: "Hex",
      identity: "A personal Mac companion.",
      voice: "Direct, warm, and precise.",
      traits: ["curious", "protective"],
      values: ["user agency"],
      boundaries: ["Never pretend an action happened."]
    )
    #expect(saved == expected)
    #expect(model.state == .loaded)
    #expect(model.statusMessage == "Personality profile saved.")
    #expect(model.errorMessage == nil)
  }

  @Test @MainActor
  func profileLoadExposesCorruptionAndKeepsTheStoreUntouched() async throws {
    let service = FakePersonalityService(profileFailure: .malformed)
    let model = HexPersonalityProfileModel(service: service)

    await model.load()

    #expect(model.state.isUnavailable == false)
    #expect(model.state.message?.contains("corrupted") == true)
    #expect(model.canSave)
    #expect(model.errorMessage?.contains("corrupted") == true)
    #expect(await service.profile == nil)
  }

  @Test @MainActor
  func memoryModelAddsEditsAndDeletesOnlyWithinItsInjectedScope() async throws {
    let scope = try PersonalMemoryScope(rawValue: "mike.hex")
    let service = FakePersonalityService()
    let model = HexPersonalMemoriesModel(scope: scope, service: service)

    await model.load()

    #expect(model.state == .empty)
    model.beginAdding()
    model.draftText = "Mike prefers technical Swift examples."
    model.draftKind = .preference
    model.draftSource = .explicitUserStatement
    model.draftIsPinned = true
    await model.saveDraft()

    let saved = try #require(await service.records.first)
    #expect(saved.scope == scope)
    #expect(saved.kind == .preference)
    #expect(saved.source == .explicitUserStatement)
    #expect(saved.isPinned)
    #expect(model.memories == [saved])

    model.beginEditing(saved)
    model.draftText = "Mike prefers concise technical Swift examples."
    model.draftKind = .projectContext
    await model.saveDraft()

    let edited = try #require(await service.records.first)
    #expect(edited.id == saved.id)
    #expect(edited.scope == scope)
    #expect(edited.createdAt == saved.createdAt)
    #expect(edited.updatedAt > saved.updatedAt)
    #expect(edited.kind == .projectContext)
    #expect(edited.source == .explicitUserStatement)

    await model.delete(edited)

    #expect(await service.records.isEmpty)
    #expect(model.state == .empty)
    #expect(model.statusMessage == "Personal memory deleted.")
  }

  @Test @MainActor
  func unavailableServicesDisableEditingAndExposeAnHonestState() async throws {
    let profileModel = HexPersonalityProfileModel(service: HexUnavailablePersonalityService())
    await profileModel.load()
    #expect(profileModel.state.isUnavailable)
    #expect(!profileModel.canEdit)

    let scope = try PersonalMemoryScope(rawValue: "mike.hex")
    let memoriesModel = HexPersonalMemoriesModel(
      scope: scope,
      service: HexUnavailablePersonalityService()
    )
    await memoriesModel.load()
    #expect(memoriesModel.state.isUnavailable)
    #expect(!memoriesModel.canEdit)
    memoriesModel.beginAdding()
    #expect(!memoriesModel.isEditorPresented)
  }

  private enum Failure: Error, Sendable {
    case malformed
    case unavailable
  }

  private actor FakePersonalityService: HexPersonalityServicing {
    var profile: PersonalityProfile?
    private(set) var records: [PersonalMemoryRecord] = []
    let profileFailure: Failure?
    let memoryFailure: Failure?

    init(
      profile: PersonalityProfile? = nil,
      profileFailure: Failure? = nil,
      memoryFailure: Failure? = nil
    ) {
      self.profile = profile
      self.profileFailure = profileFailure
      self.memoryFailure = memoryFailure
    }

    func loadProfile() async throws -> PersonalityProfile? {
      try throwIfNeeded(profileFailure)
      return profile
    }

    func saveProfile(_ profile: PersonalityProfile) async throws {
      try throwIfNeeded(profileFailure)
      self.profile = profile
    }

    func listMemories(
      scope: PersonalMemoryScope,
      text: String?,
      limit: Int
    ) async throws -> [PersonalMemoryRecord] {
      try throwIfNeeded(memoryFailure)
      let matches = records.filter { $0.scope == scope }
      return Array(matches.prefix(limit))
    }

    func saveMemory(_ record: PersonalMemoryRecord) async throws {
      try throwIfNeeded(memoryFailure)
      if let index = records.firstIndex(where: {
        $0.id == record.id && $0.scope == record.scope
      }) {
        records[index] = record
      } else {
        records.append(record)
      }
    }

    @discardableResult
    func deleteMemory(
      id: PersonalMemoryID,
      scope: PersonalMemoryScope
    ) async throws -> Bool {
      try throwIfNeeded(memoryFailure)
      let initialCount = records.count
      records.removeAll { $0.id == id && $0.scope == scope }
      return records.count != initialCount
    }

    private func throwIfNeeded(_ failure: Failure?) throws {
      guard let failure else {
        return
      }
      switch failure {
      case .malformed:
        throw PersonalityProfileStoreError.malformedProfile
      case .unavailable:
        throw HexPersonalityServiceError.unavailable
      }
    }
  }
}
