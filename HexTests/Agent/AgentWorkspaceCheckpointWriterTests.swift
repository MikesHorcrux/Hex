import Foundation
import Testing

@testable import Hex

@Suite("Checkpoint writer ordering and exact receipts")
struct AgentWorkspaceCheckpointWriterTests {
  @Test @MainActor
  func barrierCannotBeCoalescedAwayAndReceiptDoesNotWaitForLaterWrites() async throws {
    let store = BlockingStore()
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient(), conversationStore: store)
    let first = archive("First")
    let barrier = archive("Barrier")
    let later = archive("Later")
    model.queueArchiveWrite(first)
    await store.waitForCall(1)
    let receipt = Task { await model.saveArchiveNow(barrier) }
    try await waitForQueuedRevision(2, model: model)
    model.queueArchiveWrite(later)

    await store.release(1)
    await store.waitForCall(2)
    #expect(await store.attempts == [first, barrier])
    await store.release(2)
    await store.waitForCall(3)

    #expect(await receipt.value)
    #expect(await store.committed == [first, barrier])
    await store.release(3)
    await model.conversationPersistenceTask?.value
    #expect(await store.committed == [first, barrier, later])
  }

  @Test @MainActor
  func regularPendingSnapshotsCoalesceWithoutReplacingTheInFlightWrite() async throws {
    let store = BlockingStore()
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient(), conversationStore: store)
    let first = archive("First")
    let superseded = archive("Superseded")
    let latest = archive("Latest")
    model.queueArchiveWrite(first)
    await store.waitForCall(1)
    model.queueArchiveWrite(superseded)
    model.queueArchiveWrite(latest)
    #expect(model.archiveWriteQueue.count == 1)

    await store.release(1)
    await store.waitForCall(2)
    #expect(await store.attempts == [first, latest])
    await store.release(2)
    await model.conversationPersistenceTask?.value

    #expect(await store.committed == [first, latest])
    #expect(model.savedArchiveRevision == 3)
  }

  @Test @MainActor
  func failedBarrierReceiptStaysFailedWhenALaterSnapshotSucceeds() async throws {
    let store = BlockingStore(failingTitles: ["Barrier"])
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient(), conversationStore: store)
    let first = archive("First")
    let barrier = archive("Barrier")
    let later = archive("Later")
    model.queueArchiveWrite(first)
    await store.waitForCall(1)
    let receipt = Task { await model.saveArchiveNow(barrier) }
    try await waitForQueuedRevision(2, model: model)
    model.queueArchiveWrite(later)

    await store.release(1)
    await store.waitForCall(2)
    await store.release(2)
    await store.waitForCall(3)
    let barrierSaved = await receipt.value
    #expect(!barrierSaved)
    #expect(model.conversationSaveError != nil)
    await store.release(3)
    await model.conversationPersistenceTask?.value

    #expect(!barrierSaved)
    #expect(await store.committed == [first, later])
    #expect(model.conversationSaveError == nil)
  }

  @MainActor
  private func waitForQueuedRevision(_ revision: UInt64, model: AgentWorkspaceModel) async throws {
    for _ in 0..<10_000 {
      if model.archiveRevision >= revision { return }
      await Task.yield()
    }
    throw FixtureFailure.barrierWasNotQueued
  }

  private func archive(_ title: String) -> AgentConversationArchive {
    let conversation = AgentConversation(title: title)
    return AgentConversationArchive(
      selectedConversationID: conversation.id, conversations: [conversation])
  }

  private enum FixtureFailure: Error { case expectedSaveFailure, barrierWasNotQueued }

  private actor BlockingStore: AgentConversationStoring {
    let failingTitles: Set<String>
    private(set) var attempts: [AgentConversationArchive] = []
    private(set) var committed: [AgentConversationArchive] = []
    private var releases: [Int: CheckedContinuation<Void, Never>] = [:]
    private var started: [Int: [CheckedContinuation<Void, Never>]] = [:]

    init(failingTitles: Set<String> = []) {
      self.failingTitles = failingTitles
    }

    func load() async throws -> AgentConversationArchive? { committed.last }

    func save(_ archive: AgentConversationArchive) async throws {
      attempts.append(archive)
      let call = attempts.count
      await withCheckedContinuation { continuation in
        releases[call] = continuation
        for waiter in started.removeValue(forKey: call) ?? [] { waiter.resume() }
      }
      if let title = archive.conversations.first?.title, failingTitles.contains(title) {
        throw FixtureFailure.expectedSaveFailure
      }
      committed.append(archive)
    }

    nonisolated func validateForPersistence(_ archive: AgentConversationArchive) throws {
      try AgentConversationStore.validateForPersistence(archive)
    }

    func waitForCall(_ call: Int) async {
      if attempts.count >= call { return }
      await withCheckedContinuation { started[call, default: []].append($0) }
    }

    func release(_ call: Int) {
      releases.removeValue(forKey: call)?.resume()
    }
  }
}
