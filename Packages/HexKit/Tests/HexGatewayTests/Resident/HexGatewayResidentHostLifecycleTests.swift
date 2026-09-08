import Foundation
import HexGatewayKit
import HexPersistence
import Testing

@MainActor
@Suite("Resident owned storage lifecycle")
struct HexGatewayResidentHostLifecycleTests {
  @Test
  func failedScheduleStoreOpenReleasesPreviouslyOpenedJournal() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = try configuration(in: directory)
    // A directory cannot be admitted as the SQLite file. The failure occurs after composition has
    // acquired its journal, before a listener or any run is created.
    try FileManager.default.createDirectory(
      at: configuration.heartbeatDatabaseURL,
      withIntermediateDirectories: false)
    await #expect(throws: (any Error).self) {
      _ = try await HexGatewayResidentHost.open(configuration: configuration)
    }
    #expect(FileManager.default.fileExists(atPath: configuration.databaseURL.path))
    let journal = try await SQLiteAgentEventJournal.open(
      configuration:
        SQLiteAgentEventJournalConfiguration(databaseURL: configuration.databaseURL))
    try await journal.close()
  }

  @Test
  func cancelledBeforeActivationClosesBothStoresWhileHostRemainsRetained() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = try configuration(in: directory)
    let host = try await HexGatewayResidentHost.open(configuration: configuration)
    let run = Task { @MainActor in
      // Cancellation is set inside this task before run() can reach listener activation. This
      // exercises the real unwind without publishing a Mach service, installing signals, or running
      // launchd, MCP, tools, or inference.
      withUnsafeCurrentTask { $0?.cancel() }
      try await host.run()
    }
    await #expect(throws: CancellationError.self) { try await run.value }
    #expect(await host.heartbeatIsRunning() == false)
    await #expect(throws: (any Error).self) { _ = try await host.heartbeatSnapshot() }
    let journal = try await SQLiteAgentEventJournal.open(
      configuration:
        SQLiteAgentEventJournalConfiguration(databaseURL: configuration.databaseURL))
    try await journal.close()
    let schedules = try await SQLiteHexHeartbeatStore.open(
      databaseURL: configuration.heartbeatDatabaseURL)
    #expect(try await schedules.load().schedules.isEmpty)
    try await schedules.close()
    // Keep the original host alive through both reopen checks; destructor cleanup is not evidence
    // that the run's awaited teardown released its ownership.
    await #expect(throws: (any Error).self) { _ = try await host.heartbeatSnapshot() }
  }

  private func configuration(in directory: URL) throws -> HexGatewayResidentConfiguration {
    try HexGatewayResidentConfiguration(
      machServiceName: HexGatewayServiceIdentity.machServiceName,
      modelID: "fixture-model", workspaceRoot: directory,
      databaseURL: directory.appendingPathComponent("journal.sqlite"),
      apiKey: "fixture-not-a-live-key",
      heartbeatStoreURL: directory.appendingPathComponent("heartbeats.json"))
  }

  private func makeDirectory() throws -> URL {
    // Avoid Foundation's /private/var -> /var alias normalization when testing stores that reject
    // symlink ancestors. Every test owns and removes exactly its UUID directory in the checkout.
    var parent = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { parent.deleteLastPathComponent() }
    let directory = parent.appendingPathComponent(
      ".hex-host-lifecycle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    return directory
  }
}
