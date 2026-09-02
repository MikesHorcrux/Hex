import Foundation
import HexPersonality
import Observation

@MainActor
@Observable
final class HexPersonalMemoriesModel {
  let scope: PersonalMemoryScope

  private(set) var memories: [PersonalMemoryRecord] = []
  private(set) var state = HexPersonalMemoriesState.idle
  private(set) var isLoading = false
  private(set) var isSaving = false
  private(set) var statusMessage: String?
  private(set) var errorMessage: String?
  private(set) var isEditorPresented = false
  private(set) var editingMemoryID: PersonalMemoryID?

  var draftText = "" {
    didSet {
      let bounded = HexPersonalityInputLimits.bounded(
        draftText,
        maximumBytes: HexPersonalityInputLimits.memoryTextBytes
      )
      if draftText != bounded {
        draftText = bounded
      }
    }
  }

  var draftKind = PersonalMemoryKind.preference
  var draftSource = PersonalMemorySource.explicitUserStatement
  var draftIsPinned = false

  private let service: any HexPersonalityServicing
  private var editingCreatedAt: Date?
  private var hasLoaded = false

  init(
    scope: PersonalMemoryScope,
    service: any HexPersonalityServicing = HexUnavailablePersonalityService()
  ) {
    self.scope = scope
    self.service = service
  }

  var canEdit: Bool {
    hasLoaded
      && !isLoading
      && !isSaving
      && !state.isUnavailable
      && !state.isCorrupted
  }

  var canSaveDraft: Bool {
    canEdit && !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var isEditing: Bool {
    editingMemoryID != nil
  }

  var editorTitle: String {
    isEditing ? "Edit personal memory" : "Add personal memory"
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

  func beginAdding() {
    guard canEdit else {
      return
    }
    editingMemoryID = nil
    editingCreatedAt = nil
    draftText = ""
    draftKind = .preference
    draftSource = .explicitUserStatement
    draftIsPinned = false
    isEditorPresented = true
    statusMessage = nil
    errorMessage = nil
  }

  func beginEditing(_ memory: PersonalMemoryRecord) {
    guard canEdit else {
      return
    }
    editingMemoryID = memory.id
    editingCreatedAt = memory.createdAt
    draftText = memory.text
    draftKind = memory.kind
    draftSource = memory.source
    draftIsPinned = memory.isPinned
    isEditorPresented = true
    statusMessage = nil
    errorMessage = nil
  }

  func cancelEditing() {
    isEditorPresented = false
    editingMemoryID = nil
    editingCreatedAt = nil
    draftText = ""
    errorMessage = nil
  }

  func saveDraft() async {
    guard !isSaving else {
      return
    }
    guard canEdit else {
      errorMessage =
        state.isUnavailable
        ? "Personal memories are unavailable in this build."
        : "Personal memories cannot be edited while their store is unavailable or corrupted."
      return
    }
    guard !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      errorMessage = "Enter a memory before saving."
      return
    }

    let now = Date()
    let existingRecord = editingMemoryID.flatMap { id in
      memories.first { $0.id == id && $0.scope == scope }
    }
    let createdAt = existingRecord?.createdAt ?? editingCreatedAt ?? now
    let updatedAt = Self.updatedTimestamp(now: now, existing: existingRecord?.updatedAt)
    let record: PersonalMemoryRecord
    do {
      record = try PersonalMemoryRecord(
        scope: scope,
        id: editingMemoryID ?? PersonalMemoryID(),
        kind: draftKind,
        text: draftText,
        source: draftSource,
        createdAt: createdAt,
        updatedAt: updatedAt,
        isPinned: draftIsPinned
      )
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
      try await service.saveMemory(record)
      upsert(record)
      state = memories.isEmpty ? .empty : .loaded
      statusMessage = "Personal memory saved."
      errorMessage = nil
      isEditorPresented = false
      editingMemoryID = nil
      editingCreatedAt = nil
      draftText = ""
    } catch is CancellationError {
      return
    } catch {
      errorMessage = Self.operationMessage(for: error)
    }
  }

  func delete(_ memory: PersonalMemoryRecord) async {
    guard !isSaving else {
      return
    }
    guard canEdit else {
      errorMessage =
        state.isUnavailable
        ? "Personal memories are unavailable in this build."
        : "Personal memories cannot be deleted while their store is unavailable or corrupted."
      return
    }

    isSaving = true
    errorMessage = nil
    statusMessage = nil
    defer {
      isSaving = false
    }

    do {
      let removed = try await service.deleteMemory(id: memory.id, scope: scope)
      guard removed else {
        errorMessage = "That memory is no longer available. Reload the list and try again."
        await reload()
        return
      }
      memories.removeAll { $0.id == memory.id && $0.scope == memory.scope }
      state = memories.isEmpty ? .empty : .loaded
      statusMessage = "Personal memory deleted."
      if editingMemoryID == memory.id {
        cancelEditing()
      }
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
      let loaded = try await service.listMemories(
        scope: scope,
        text: nil,
        limit: HexPersonalityInputLimits.memoryListLimit
      )
      memories = loaded
      state = memories.isEmpty ? .empty : .loaded
      hasLoaded = true
    } catch is CancellationError {
      state = .idle
    } catch {
      memories = []
      state = Self.state(for: error)
      errorMessage = state.message
      hasLoaded = true
    }
  }

  private func upsert(_ record: PersonalMemoryRecord) {
    if let index = memories.firstIndex(where: { $0.id == record.id && $0.scope == record.scope }) {
      memories[index] = record
    } else {
      memories.append(record)
    }
    memories.sort(by: Self.precedes)
  }

  private static func precedes(
    _ left: PersonalMemoryRecord,
    _ right: PersonalMemoryRecord
  ) -> Bool {
    if left.isPinned != right.isPinned {
      return left.isPinned
    }
    if left.updatedAt != right.updatedAt {
      return left.updatedAt > right.updatedAt
    }
    if left.createdAt != right.createdAt {
      return left.createdAt > right.createdAt
    }
    return left.id.rawValue < right.id.rawValue
  }

  private static func updatedTimestamp(now: Date, existing: Date?) -> Date {
    guard let existing else {
      return now
    }
    return max(now, existing.addingTimeInterval(0.001))
  }

  private static func state(for error: any Error) -> HexPersonalMemoriesState {
    if let error = error as? HexPersonalityServiceError, error == .unavailable {
      return .unavailable(error.localizedDescription)
    }
    if let error = error as? JSONPersonalMemoryStoreError {
      switch error {
      case .malformedStore, .recordsTooLarge:
        return .corrupted(
          "The saved personal-memory store is corrupted or exceeds its safe bound. Editing is disabled until it is repaired."
        )
      case .invalidFileURL, .invalidConfiguration:
        return .unavailable("The personal-memory store is unavailable in this build.")
      case .unsafeFile, .lockFailure, .encodingFailure, .ioFailure:
        return .failed("Personal memories could not be loaded. Try again.")
      }
    }
    return .failed("Personal memories could not be loaded. Try again.")
  }

  private static func validationMessage(for error: any Error) -> String {
    if let error = error as? PersonalMemoryError {
      switch error {
      case .invalidIdentifier:
        return "The memory identifier is invalid."
      case .invalidText:
        return "Enter a memory within the allowed size."
      case .invalidTimestamp:
        return "The memory timestamp is invalid. Try again."
      }
    }
    return "Check the memory text and try again."
  }

  private static func operationMessage(for error: any Error) -> String {
    if let error = error as? HexPersonalityServiceError, error == .unavailable {
      return error.localizedDescription
    }
    if let error = error as? PersonalMemoryStoreError {
      switch error {
      case .staleUpdate:
        return "This memory changed elsewhere. Reload the list before editing it again."
      case .capacityExceeded:
        return "The personal-memory store is full. Delete an entry before adding another."
      case .byteLimitExceeded:
        return "The personal-memory store has reached its size limit."
      case .invalidConfiguration, .invalidQuery, .serializationFailed:
        return "The personal memory could not be saved. Try again."
      }
    }
    if let error = error as? JSONPersonalMemoryStoreError {
      switch error {
      case .unsafeFile:
        return "The personal-memory location is not safe to write."
      case .lockFailure:
        return "The personal-memory store is busy. Try again."
      case .malformedStore, .recordsTooLarge:
        return "The personal-memory store is corrupted or exceeds its safe bound."
      case .invalidFileURL, .invalidConfiguration, .encodingFailure, .ioFailure:
        return "The personal memory could not be saved. Try again."
      }
    }
    return "The personal memory could not be saved. Try again."
  }
}
