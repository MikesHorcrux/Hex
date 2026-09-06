import Foundation
import HexCore

actor FileArtifactWriteSession: ArtifactWriteSession {
  private let store: FileArtifactStore
  private let id: UUID
  private var appending = false
  private var abandoned = false
  private var completion: Bool?
  private var finishTask: Task<ArtifactReference, Error>?
  private var finished: ArtifactReference?

  init(store: FileArtifactStore, id: UUID) {
    self.store = store
    self.id = id
  }

  deinit {
    let store = store
    let id = id
    Task { await store.abandon(id) }
  }

  func append(_ data: Data) async throws {
    guard !appending, !abandoned, completion == nil else { throw ArtifactStoreError.invalidRequest }
    appending = true
    defer { appending = false }
    try await store.append(data, to: id)
  }

  func finish(isComplete: Bool) async throws -> ArtifactReference {
    guard !appending, !abandoned, completion == nil || completion == isComplete else {
      throw ArtifactStoreError.invalidRequest
    }
    if let finished { return finished }
    completion = isComplete
    let task: Task<ArtifactReference, Error>
    if let finishTask {
      task = finishTask
    } else {
      let store = store
      let id = id
      task = Task { try await store.finish(id, isComplete: isComplete) }
      finishTask = task
    }
    do {
      let result = try await task.value
      finished = result
      finishTask = nil
      return result
    } catch {
      finishTask = nil
      throw error
    }
  }

  func abandon() async {
    if let finishTask {
      _ = try? await finishTask.value
      return
    }
    guard finished == nil else { return }
    abandoned = true
    await store.abandon(id)
  }
}
