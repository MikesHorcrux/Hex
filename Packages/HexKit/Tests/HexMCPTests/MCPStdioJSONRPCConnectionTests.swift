import Darwin
import Foundation
import HexCore
import Synchronization
import Testing

@testable import HexMCP

@Suite("MCP stdio JSON-RPC connection", .serialized)
struct MCPStdioJSONRPCConnectionTests {
  @Test("Executes a private snapshot when the configured path is replaced before spawn")
  func configuredExecutableReplacementNeverRuns() async throws {
    let fixtureDirectory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
    let configuredExecutable = fixtureDirectory.appendingPathComponent("server")
    let replacementExecutable = fixtureDirectory.appendingPathComponent("replacement")
    let marker = fixtureDirectory.appendingPathComponent("attacker-ran")
    try writeLegitimateExecutable(to: configuredExecutable)
    try writeAttackerExecutable(to: replacementExecutable, marker: marker)
    let configuration = try mutableExecutableConfiguration(
      executableURL: configuredExecutable
    )
    let observedLaunchPath = Mutex<String?>(nil)
    let replacementResult = Mutex<Int32?>(nil)
    let configuredPath = configuredExecutable.path
    let replacementPath = replacementExecutable.path
    let connection = MCPStdioJSONRPCConnection(
      configuration: configuration,
      spawnProcess: { configuration in
        try MCPStdioProcessSpawner.spawn(
          configuration,
          beforeExecution: { configuredPath, launchPath in
            observedLaunchPath.withLock { $0 = launchPath }
            replacementResult.withLock { result in
              result = Darwin.rename(replacementPath, configuredPath)
            }
          }
        )
      }
    )
    let session = LocalMCPClientSession(configuration: configuration, connection: connection)

    try await session.connect()
    await session.disconnect()

    #expect(replacementResult.withLock { $0 } == 0)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    let launchPath = try #require(observedLaunchPath.withLock { $0 })
    #expect(launchPath != configuredPath)
    #expect(!FileManager.default.fileExists(atPath: launchPath))
    #expect(
      !FileManager.default.fileExists(
        atPath: URL(fileURLWithPath: launchPath).deletingLastPathComponent().path))
  }

  @Test("Rejects in-place executable mutation after validation without running mutated bytes")
  func inPlaceExecutableMutationNeverRuns() async throws {
    let fixtureDirectory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
    let configuredExecutable = fixtureDirectory.appendingPathComponent("server")
    let marker = fixtureDirectory.appendingPathComponent("attacker-ran")
    try writeLegitimateExecutable(to: configuredExecutable)
    let legitimateByteCount = try Data(contentsOf: configuredExecutable).count
    var paddedMaliciousBytes = Data(attackerScript(marker: marker).utf8)
    #expect(paddedMaliciousBytes.count < legitimateByteCount)
    paddedMaliciousBytes.append(
      Data(repeating: 32, count: legitimateByteCount - paddedMaliciousBytes.count)
    )
    let maliciousBytes = paddedMaliciousBytes
    let mutationResult = Mutex<Bool?>(nil)
    let observedSnapshotPath = Mutex<String?>(nil)
    let configuration = try mutableExecutableConfiguration(
      executableURL: configuredExecutable
    )
    let connection = MCPStdioJSONRPCConnection(
      configuration: configuration,
      spawnProcess: { configuration in
        try MCPStdioProcessSpawner.spawn(
          configuration,
          afterSourceValidation: { snapshotPath in
            observedSnapshotPath.withLock { $0 = snapshotPath }
            mutationResult.withLock { result in
              result = Self.overwriteFile(
                atPath: configuredExecutable.path,
                with: maliciousBytes
              )
            }
          }
        )
      }
    )
    let session = LocalMCPClientSession(configuration: configuration, connection: connection)

    await #expect(throws: MCPClientSessionError.connectionClosed) {
      try await session.connect()
    }

    #expect(mutationResult.withLock { $0 } == true)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    let snapshotPath = try #require(observedSnapshotPath.withLock { $0 })
    #expect(!FileManager.default.fileExists(atPath: snapshotPath))
    #expect(
      !FileManager.default.fileExists(
        atPath: URL(fileURLWithPath: snapshotPath).deletingLastPathComponent().path
      )
    )
  }

  @Test("Rejects oversized and hard-linked executable sources before launch")
  func rejectsUnsafeExecutableSources() async throws {
    let fixtureDirectory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
    let oversizedExecutable = fixtureDirectory.appendingPathComponent("oversized")
    let oversizedDescriptor = Darwin.open(
      oversizedExecutable.path,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
      0o700
    )
    #expect(oversizedDescriptor >= 0)
    guard oversizedDescriptor >= 0 else { return }
    #expect(
      ftruncate(
        oversizedDescriptor,
        MCPExecutableSnapshot.maximumExecutableBytes + 1
      ) == 0
    )
    Darwin.close(oversizedDescriptor)

    let hardLinkedExecutable = fixtureDirectory.appendingPathComponent("hard-linked")
    let secondLink = fixtureDirectory.appendingPathComponent("second-link")
    try writeLegitimateExecutable(to: hardLinkedExecutable)
    #expect(Darwin.link(hardLinkedExecutable.path, secondLink.path) == 0)

    for executable in [oversizedExecutable, hardLinkedExecutable] {
      let configuration = try mutableExecutableConfiguration(executableURL: executable)
      let session = LocalMCPClientSession(configuration: configuration)
      await #expect(throws: MCPClientSessionError.connectionClosed) {
        try await session.connect()
      }
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: fixtureDirectory.appendingPathComponent("attacker-ran").path))
  }

  @Test("Rejects symlinked, nonregular, and unsafely permissioned executable sources")
  func rejectsInvalidExecutableFileKindsAndPermissions() async throws {
    let fixtureDirectory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
    let validExecutable = fixtureDirectory.appendingPathComponent("valid")
    let symlinkedExecutable = fixtureDirectory.appendingPathComponent("symlink")
    let nonregularExecutable = fixtureDirectory.appendingPathComponent(
      "directory", isDirectory: true)
    let fifoExecutable = fixtureDirectory.appendingPathComponent("fifo")
    let writableExecutable = fixtureDirectory.appendingPathComponent("group-writable")
    let nonexecutableFile = fixtureDirectory.appendingPathComponent("nonexecutable")
    let setIDExecutable = fixtureDirectory.appendingPathComponent("set-id")
    try writeLegitimateExecutable(to: validExecutable)
    #expect(Darwin.symlink(validExecutable.path, symlinkedExecutable.path) == 0)
    try FileManager.default.createDirectory(
      at: nonregularExecutable, withIntermediateDirectories: false)
    #expect(Darwin.mkfifo(fifoExecutable.path, 0o700) == 0)
    try writeLegitimateExecutable(to: writableExecutable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o720],
      ofItemAtPath: writableExecutable.path
    )
    try Data("not executable".utf8).write(to: nonexecutableFile, options: .withoutOverwriting)
    try writeLegitimateExecutable(to: setIDExecutable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o4_700],
      ofItemAtPath: setIDExecutable.path
    )

    let invalidExecutables = [
      symlinkedExecutable,
      nonregularExecutable,
      fifoExecutable,
      writableExecutable,
      nonexecutableFile,
      setIDExecutable,
    ]
    for executable in invalidExecutables {
      let configuration = try mutableExecutableConfiguration(executableURL: executable)
      let session = LocalMCPClientSession(configuration: configuration)
      await #expect(throws: MCPClientSessionError.connectionClosed) {
        try await session.connect()
      }
    }
  }

  @Test("Rejects source growth and short reads while building the private snapshot")
  func rejectsSourceSizeChangesDuringSnapshot() async throws {
    let fixtureDirectory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

    for mutation in ["growth", "short-read"] {
      let executable = fixtureDirectory.appendingPathComponent(mutation)
      try writeLegitimateExecutable(to: executable)
      let configuration = try mutableExecutableConfiguration(executableURL: executable)
      let observedSnapshotPath = Mutex<String?>(nil)
      let connection = MCPStdioJSONRPCConnection(
        configuration: configuration,
        spawnProcess: { configuration in
          try MCPStdioProcessSpawner.spawn(
            configuration,
            afterSourceValidation: { snapshotPath in
              observedSnapshotPath.withLock { $0 = snapshotPath }
              switch mutation {
              case "growth":
                #expect(Self.appendByte(atPath: executable.path))
              default:
                #expect(Darwin.truncate(executable.path, 1) == 0)
              }
            }
          )
        }
      )
      let session = LocalMCPClientSession(configuration: configuration, connection: connection)

      await #expect(throws: MCPClientSessionError.connectionClosed) {
        try await session.connect()
      }

      let snapshotPath = try #require(observedSnapshotPath.withLock { $0 })
      #expect(!FileManager.default.fileExists(atPath: snapshotPath))
      #expect(
        !FileManager.default.fileExists(
          atPath: URL(fileURLWithPath: snapshotPath).deletingLastPathComponent().path
        )
      )
    }
  }

  @Test("Repeated rejected snapshots release their private files and descriptors")
  func repeatedRejectedSnapshotsDoNotLeakResources() throws {
    let fixtureDirectory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
    let descriptorCountBefore = try openDescriptorCount()

    for index in 0..<32 {
      let executable = fixtureDirectory.appendingPathComponent("server-\(index)")
      try writeLegitimateExecutable(to: executable)
      let configuration = try mutableExecutableConfiguration(executableURL: executable)
      let observedSnapshotPath = Mutex<String?>(nil)

      #expect(throws: MCPClientSessionError.connectionClosed) {
        _ = try MCPStdioProcessSpawner.spawn(
          configuration,
          afterSourceValidation: { snapshotPath in
            observedSnapshotPath.withLock { $0 = snapshotPath }
            #expect(Darwin.truncate(executable.path, 1) == 0)
          }
        )
      }

      let snapshotPath = try #require(observedSnapshotPath.withLock { $0 })
      #expect(!FileManager.default.fileExists(atPath: snapshotPath))
      #expect(
        !FileManager.default.fileExists(
          atPath: URL(fileURLWithPath: snapshotPath).deletingLastPathComponent().path
        )
      )
    }

    #expect(try openDescriptorCount() <= descriptorCountBefore)
  }

  @Test("Preserves bundle-relative runtime dependencies in a private snapshot")
  func launchesPrivateBundleSnapshotWithRuntimeDependency() async throws {
    let fixtureDirectory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
    let bundle = try makeRuntimeDependencyBundle(in: fixtureDirectory)
    let observedLaunchPath = Mutex<String?>(nil)
    let stagedDependencyWasPresent = Mutex(false)
    let configuration = try MCPServerConfiguration(
      serverID: "bundle-fixture",
      executableURL: bundle.executable,
      arguments: [],
      workingDirectory: URL(fileURLWithPath: "/"),
      environment: ["PATH": "/usr/bin:/bin"],
      requestTimeoutMilliseconds: 2_000,
      shutdownGraceMilliseconds: 50,
      maximumMessageBytes: 4 * 1_024
    )
    let connection = MCPStdioJSONRPCConnection(
      configuration: configuration,
      spawnProcess: { configuration in
        try MCPStdioProcessSpawner.spawn(
          configuration,
          beforeExecution: { _, launchPath in
            observedLaunchPath.withLock { $0 = launchPath }
            let snapshotRoot = URL(fileURLWithPath: launchPath)
              .deletingLastPathComponent()
              .deletingLastPathComponent()
              .deletingLastPathComponent()
            stagedDependencyWasPresent.withLock {
              $0 = FileManager.default.fileExists(
                atPath: snapshotRoot.appendingPathComponent(
                  "Contents/SnapshotRuntime/MCPFixture.framework/MCPFixture"
                ).path
              )
            }
          }
        )
      }
    )
    let session = LocalMCPClientSession(configuration: configuration, connection: connection)

    try await session.connect()
    await session.disconnect()

    let launchPath = try #require(observedLaunchPath.withLock { $0 })
    #expect(launchPath != bundle.executable.path)
    #expect(launchPath.hasSuffix("/Contents/MacOS/server"))
    #expect(stagedDependencyWasPresent.withLock { $0 })
    #expect(!FileManager.default.fileExists(atPath: bundle.externalMarker.path))
    let snapshotRoot = URL(fileURLWithPath: launchPath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    #expect(!FileManager.default.fileExists(atPath: snapshotRoot.path))
  }

  @Test("Builds the installed Xcode bridge closure without launching it")
  func snapshotsInstalledXcodeBridgeRuntimeClosure() throws {
    let configuration = try MCPServerConfiguration.xcode(
      sourceEnvironment: ["PATH": "/usr/bin:/bin"],
      developerDirectory: URL(
        fileURLWithPath: "/Applications/Xcode.app/Contents/Developer",
        isDirectory: true
      )
    )
    let sourceDescriptor = Darwin.open(
      configuration.executableURL.path,
      O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
    )
    #expect(sourceDescriptor >= 0)
    guard sourceDescriptor >= 0 else { return }
    defer { Darwin.close(sourceDescriptor) }
    var sourceStatus = stat()
    #expect(fstat(sourceDescriptor, &sourceStatus) == 0)

    var snapshot: MCPExecutableSnapshot? = try MCPExecutableSnapshot.create(
      from: sourceDescriptor,
      initialStatus: sourceStatus,
      sourcePath: configuration.executableURL.path,
      afterSourceValidation: nil
    )
    let executablePath = try #require(snapshot?.executablePath)
    let snapshotRoot = URL(fileURLWithPath: executablePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    #expect(executablePath.hasSuffix("/Contents/Developer/usr/bin/mcpbridge"))
    #expect(snapshot?.isIntact() == true)
    #expect(
      FileManager.default.fileExists(
        atPath: snapshotRoot.appendingPathComponent(
          "Frameworks/PlugIns/IDEIntelligenceFoundation.framework/Versions/A/IDEIntelligenceFoundation"
        ).path
      )
    )
    #expect(
      FileManager.default.fileExists(
        atPath: snapshotRoot.appendingPathComponent(
          "Frameworks/PlugIns/IDEIntelligenceMessaging.framework/Versions/A/IDEIntelligenceMessaging"
        ).path
      )
    )

    snapshot = nil

    #expect(!FileManager.default.fileExists(atPath: snapshotRoot.path))
  }

  @Test("Rejects an oversized bundle runtime dependency before launch")
  func rejectsOversizedBundleRuntimeDependency() async throws {
    let fixtureDirectory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
    let bundle = try makeRuntimeDependencyBundle(in: fixtureDirectory)
    #expect(
      Darwin.truncate(
        bundle.dependency.path,
        MCPExecutableSnapshot.maximumExecutableBytes + 1
      ) == 0
    )
    let observedSnapshotPath = Mutex<String?>(nil)
    let executionReached = Mutex(false)
    let configuration = try MCPServerConfiguration(
      serverID: "oversized-bundle-fixture",
      executableURL: bundle.executable,
      arguments: [],
      workingDirectory: URL(fileURLWithPath: "/"),
      environment: ["PATH": "/usr/bin:/bin"],
      requestTimeoutMilliseconds: 2_000,
      shutdownGraceMilliseconds: 50,
      maximumMessageBytes: 4 * 1_024
    )
    let connection = MCPStdioJSONRPCConnection(
      configuration: configuration,
      spawnProcess: { configuration in
        try MCPStdioProcessSpawner.spawn(
          configuration,
          afterSourceValidation: { snapshotPath in
            observedSnapshotPath.withLock { $0 = snapshotPath }
          },
          beforeExecution: { _, _ in
            executionReached.withLock { $0 = true }
          }
        )
      }
    )
    let session = LocalMCPClientSession(configuration: configuration, connection: connection)

    await #expect(throws: MCPClientSessionError.connectionClosed) {
      try await session.connect()
    }

    let snapshotPath = try #require(observedSnapshotPath.withLock { $0 })
    let snapshotRoot = URL(fileURLWithPath: snapshotPath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    #expect(!executionReached.withLock { $0 })
    #expect(!FileManager.default.fileExists(atPath: snapshotRoot.path))
  }

  @Test("Rejects a bundle dependency tree beyond the snapshot depth bound")
  func rejectsExcessiveBundleDependencyDepth() async throws {
    let fixtureDirectory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
    let bundle = try makeRuntimeDependencyBundle(in: fixtureDirectory)
    var deepDirectory = bundle.dependency.deletingLastPathComponent()
      .appendingPathComponent("Resources", isDirectory: true)
    for _ in 0..<MCPExecutableSnapshot.maximumSnapshotPathDepth {
      deepDirectory.appendPathComponent("d", isDirectory: true)
    }
    try FileManager.default.createDirectory(
      at: deepDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let observedSnapshotPath = Mutex<String?>(nil)
    let executionReached = Mutex(false)
    let configuration = try MCPServerConfiguration(
      serverID: "deep-bundle-fixture",
      executableURL: bundle.executable,
      arguments: [],
      workingDirectory: URL(fileURLWithPath: "/"),
      environment: ["PATH": "/usr/bin:/bin"],
      requestTimeoutMilliseconds: 2_000,
      shutdownGraceMilliseconds: 50,
      maximumMessageBytes: 4 * 1_024
    )
    let connection = MCPStdioJSONRPCConnection(
      configuration: configuration,
      spawnProcess: { configuration in
        try MCPStdioProcessSpawner.spawn(
          configuration,
          afterSourceValidation: { snapshotPath in
            observedSnapshotPath.withLock { $0 = snapshotPath }
          },
          beforeExecution: { _, _ in
            executionReached.withLock { $0 = true }
          }
        )
      }
    )
    let session = LocalMCPClientSession(configuration: configuration, connection: connection)

    await #expect(throws: MCPClientSessionError.connectionClosed) {
      try await session.connect()
    }

    let snapshotPath = try #require(observedSnapshotPath.withLock { $0 })
    let snapshotRoot = URL(fileURLWithPath: snapshotPath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    #expect(!executionReached.withLock { $0 })
    #expect(!FileManager.default.fileExists(atPath: snapshotRoot.path))
  }

  @Test("Completed snapshot cleanup preserves a replacement directory")
  func completedSnapshotCleanupPreservesReplacementDirectory() throws {
    let fixtureDirectory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
    let source = fixtureDirectory.appendingPathComponent("server")
    let renamedSnapshot = fixtureDirectory.appendingPathComponent("renamed-snapshot")
    try writeLegitimateExecutable(to: source)
    let sourceDescriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    #expect(sourceDescriptor >= 0)
    guard sourceDescriptor >= 0 else { return }
    defer { Darwin.close(sourceDescriptor) }
    var sourceStatus = stat()
    #expect(fstat(sourceDescriptor, &sourceStatus) == 0)

    var snapshot: MCPExecutableSnapshot? = try MCPExecutableSnapshot.create(
      from: sourceDescriptor,
      initialStatus: sourceStatus,
      afterSourceValidation: nil
    )
    let executablePath = try #require(snapshot?.executablePath)
    let snapshotRoot = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
    defer {
      try? FileManager.default.removeItem(at: snapshotRoot)
      try? FileManager.default.removeItem(at: renamedSnapshot)
    }
    #expect(Darwin.rename(snapshotRoot.path, renamedSnapshot.path) == 0)
    #expect(Darwin.mkdir(snapshotRoot.path, 0o700) == 0)

    snapshot = nil

    #expect(FileManager.default.fileExists(atPath: snapshotRoot.path))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: renamedSnapshot.path).isEmpty
    )
  }

  @Test("Rejected snapshot cleanup preserves a replacement directory")
  func rejectedSnapshotCleanupPreservesReplacementDirectory() throws {
    let fixtureDirectory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
    let source = fixtureDirectory.appendingPathComponent("server")
    let renamedSnapshot = fixtureDirectory.appendingPathComponent("renamed-rejected-snapshot")
    try writeLegitimateExecutable(to: source)
    let sourceDescriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    #expect(sourceDescriptor >= 0)
    guard sourceDescriptor >= 0 else { return }
    defer { Darwin.close(sourceDescriptor) }
    var sourceStatus = stat()
    #expect(fstat(sourceDescriptor, &sourceStatus) == 0)
    let observedSnapshotRoot = Mutex<String?>(nil)
    let mutationSucceeded = Mutex(false)

    #expect(throws: MCPClientSessionError.connectionClosed) {
      _ = try MCPExecutableSnapshot.create(
        from: sourceDescriptor,
        initialStatus: sourceStatus,
        afterSourceValidation: { snapshotPath in
          let snapshotRoot = URL(fileURLWithPath: snapshotPath).deletingLastPathComponent().path
          observedSnapshotRoot.withLock { $0 = snapshotRoot }
          let renamed = Darwin.rename(snapshotRoot, renamedSnapshot.path) == 0
          let replaced = Darwin.mkdir(snapshotRoot, 0o700) == 0
          let truncated = Darwin.truncate(source.path, 1) == 0
          mutationSucceeded.withLock { $0 = renamed && replaced && truncated }
        }
      )
    }

    let snapshotRoot = try #require(observedSnapshotRoot.withLock { $0 })
    defer {
      try? FileManager.default.removeItem(atPath: snapshotRoot)
      try? FileManager.default.removeItem(at: renamedSnapshot)
    }
    #expect(mutationSucceeded.withLock { $0 })
    #expect(FileManager.default.fileExists(atPath: snapshotRoot))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: renamedSnapshot.path).isEmpty
    )
  }

  @Test("Rejected snapshot cleanup preserves a replacement entry")
  func rejectedSnapshotCleanupPreservesReplacementEntry() throws {
    let fixtureDirectory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
    let source = fixtureDirectory.appendingPathComponent("server")
    try writeLegitimateExecutable(to: source)
    let sourceDescriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    #expect(sourceDescriptor >= 0)
    guard sourceDescriptor >= 0 else { return }
    defer { Darwin.close(sourceDescriptor) }
    var sourceStatus = stat()
    #expect(fstat(sourceDescriptor, &sourceStatus) == 0)
    let observedSnapshotPath = Mutex<String?>(nil)
    let replacementBytes = Data("replacement".utf8)
    let replacementSucceeded = Mutex(false)

    #expect(throws: MCPClientSessionError.connectionClosed) {
      _ = try MCPExecutableSnapshot.create(
        from: sourceDescriptor,
        initialStatus: sourceStatus,
        afterSourceValidation: { snapshotPath in
          observedSnapshotPath.withLock { $0 = snapshotPath }
          replacementSucceeded.withLock {
            $0 = Self.replaceFile(atPath: snapshotPath, with: replacementBytes)
          }
        }
      )
    }

    let snapshotPath = try #require(observedSnapshotPath.withLock { $0 })
    let snapshotRoot = URL(fileURLWithPath: snapshotPath).deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: snapshotRoot) }
    #expect(replacementSucceeded.withLock { $0 })
    #expect(try Data(contentsOf: URL(fileURLWithPath: snapshotPath)) == replacementBytes)
  }

  @Test("Cancellation releases a live executable snapshot after terminating the child")
  func cancellationCleansLiveSnapshot() async throws {
    let fixtureDirectory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
    let executable = fixtureDirectory.appendingPathComponent("silent-server")
    try writeSilentExecutable(to: executable)
    let configuration = try mutableExecutableConfiguration(executableURL: executable)
    let spawnReached = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    let observedSnapshotPath = Mutex<String?>(nil)
    let connection = MCPStdioJSONRPCConnection(
      configuration: configuration,
      spawnProcess: { configuration in
        try MCPStdioProcessSpawner.spawn(
          configuration,
          beforeExecution: { _, launchPath in
            observedSnapshotPath.withLock { $0 = launchPath }
            spawnReached.continuation.yield()
          }
        )
      }
    )
    let session = LocalMCPClientSession(configuration: configuration, connection: connection)
    let connectTask = Task {
      try await session.connect()
    }

    var spawnEvents = spawnReached.stream.makeAsyncIterator()
    await #expect(spawnEvents.next() != nil)
    connectTask.cancel()
    await #expect(throws: CancellationError.self) {
      try await connectTask.value
    }
    await session.disconnect()

    let snapshotPath = try #require(observedSnapshotPath.withLock { $0 })
    #expect(!FileManager.default.fileExists(atPath: snapshotPath))
    #expect(
      !FileManager.default.fileExists(
        atPath: URL(fileURLWithPath: snapshotPath).deletingLastPathComponent().path
      )
    )
  }

  @Test("Does not inherit unrelated parent file descriptors")
  func doesNotInheritUnrelatedDescriptors() async throws {
    let sourceDescriptor = Darwin.open("/dev/null", O_RDONLY)
    #expect(sourceDescriptor >= 0)
    defer {
      if sourceDescriptor >= 0 { Darwin.close(sourceDescriptor) }
    }
    let inheritedCandidate = fcntl(sourceDescriptor, F_DUPFD, 200)
    #expect(inheritedCandidate >= 200)
    defer {
      if inheritedCandidate >= 0 { Darwin.close(inheritedCandidate) }
    }
    #expect(fcntl(inheritedCandidate, F_SETFD, 0) == 0)
    let program =
      #"BEGIN { inherited = (system("test -e /dev/fd/\#(inheritedCandidate)") == 0 ? "leaked" : "closed") } { print "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"state\":\"" inherited "\"}}"; fflush(); exit }"#
    let connection = MCPStdioJSONRPCConnection(
      configuration: try configuration(program: program)
    )

    try await connection.connect()
    let response = try await connection.request(method: "fixture", params: .object([:]))

    #expect(response.mcpObject?["state"] == .string("closed"))
    await connection.disconnect()
  }

  @Test("Round trips a bounded response through a real child process")
  func roundTripsResponse() async throws {
    let connection = MCPStdioJSONRPCConnection(
      configuration: try configuration(
        program: #"{ print "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}"; fflush(); }"#
      )
    )
    try await connection.connect()
    defer { Task { await connection.disconnect() } }

    let response = try await connection.request(
      method: "test/echo",
      params: .object(["value": .string("hello")])
    )

    #expect(response == .object(["ok": .boolean(true)]))
  }

  @Test("Answers unsupported server requests before accepting the matching response")
  func answersUnsupportedServerRequests() async throws {
    let program =
      #"NR == 1 { print "{\"jsonrpc\":\"2.0\",\"id\":\"server-1\",\"method\":\"roots/list\",\"params\":{}}"; fflush(); next } NR == 2 { status = index($0, "\"code\":-32601") ? "method-not-found" : "unexpected"; print "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"reply\":\"" status "\"}}"; fflush(); }"#
    let connection = MCPStdioJSONRPCConnection(
      configuration: try configuration(program: program)
    )
    try await connection.connect()
    defer { Task { await connection.disconnect() } }

    let response = try await connection.request(
      method: "test/request",
      params: .object([:])
    )

    #expect(response == .object(["reply": .string("method-not-found")]))
  }

  @Test("Replies to a peer ping with an empty result object")
  func repliesToPeerPing() async throws {
    let program =
      #"NR == 1 { print "{\"jsonrpc\":\"2.0\",\"id\":\"server-ping\",\"method\":\"ping\"}"; fflush(); next } NR == 2 { status = index($0, "\"id\":\"server-ping\"") && index($0, "\"result\":{}") ? "empty-result" : "unexpected"; print "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"reply\":\"" status "\"}}"; fflush(); }"#
    let connection = MCPStdioJSONRPCConnection(
      configuration: try configuration(program: program)
    )
    try await connection.connect()
    defer { Task { await connection.disconnect() } }

    let response = try await connection.request(
      method: "test/ping",
      params: .object([:])
    )

    #expect(response == .object(["reply": .string("empty-result")]))
  }

  @Test("Rejects canonical duplicate response members")
  func rejectsCanonicalDuplicateMembers() async throws {
    let connection = MCPStdioJSONRPCConnection(
      configuration: try configuration(
        program:
          #"{ print "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true,\"\\u006fk\":false}}"; fflush(); }"#
      )
    )
    try await connection.connect()

    await #expect(throws: MCPClientSessionError.protocolViolation) {
      try await connection.request(method: "test/duplicate", params: .object([:]))
    }
    await connection.disconnect()
  }

  @Test("Times out a silent server and closes its process group")
  func timesOutSilentServer() async throws {
    let connection = MCPStdioJSONRPCConnection(
      configuration: try configuration(
        program: #"{ while (1) { } }"#,
        requestTimeoutMilliseconds: 50
      )
    )
    try await connection.connect()

    await #expect(throws: MCPClientSessionError.requestTimedOut) {
      try await connection.request(method: "test/timeout", params: .object([:]))
    }
    await connection.disconnect()
  }

  @Test("Reconnects cleanly across process and descriptor generations")
  func reconnectsAcrossGenerations() async throws {
    let connection = MCPStdioJSONRPCConnection(
      configuration: try configuration(
        program: #"{ print "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}"; fflush(); }"#
      )
    )

    for _ in 0..<10 {
      try await connection.connect()
      let response = try await connection.request(
        method: "test/reconnect",
        params: .object([:])
      )
      #expect(response == .object(["ok": .boolean(true)]))
      await connection.disconnect()
    }
  }

  @Test("Reentrant shutdown shares completion and cannot clobber a replacement")
  func reentrantShutdownCannotClobberReplacement() async throws {
    for _ in 0..<20 {
      let configuration = try catConfiguration()
      let terminator = GatedProcessTerminator()
      let connection = MCPStdioJSONRPCConnection(
        configuration: configuration,
        terminateProcess: { spawned in
          await terminator.terminate(
            spawned,
            shutdownGraceMilliseconds: configuration.shutdownGraceMilliseconds
          )
        }
      )
      try await connection.connect()
      let encodedFirstProcess = await connection.process
      let firstProcess = try #require(encodedFirstProcess)

      let encodedFirstShutdown = await connection.beginShutdown(
        error: MCPClientSessionError.connectionClosed
      )
      let firstShutdown = try #require(encodedFirstShutdown)
      await terminator.waitUntilFirstTerminationStarts()
      let encodedReentrantShutdown = await connection.beginShutdown(
        error: MCPClientSessionError.connectionClosed
      )
      let reentrantShutdown = try #require(encodedReentrantShutdown)

      #expect(firstShutdown === reentrantShutdown)
      #expect(await terminator.invocationCount() == 1)
      if case .closing = await connection.state {
        // Expected while the shared termination operation is gated.
      } else {
        Issue.record("Shutdown published disconnected before termination completed")
      }

      let reconnect = Task {
        try await connection.connect()
      }
      for _ in 0..<20 {
        await Task.yield()
      }
      #expect(await connection.generation == firstShutdown.generation)
      if case .closing = await connection.state {
        // Reconnect must remain behind the in-flight shutdown.
      } else {
        Issue.record("Reconnect proceeded before shutdown completed")
      }

      await terminator.releaseFirstTermination()
      try await reconnect.value
      let encodedReplacement = await connection.process
      let replacement = try #require(encodedReplacement)

      #expect(await connection.generation == firstShutdown.generation + 1)
      #expect(replacement.processID != firstProcess.processID)
      #expect(Darwin.kill(firstProcess.processID, 0) == -1 && errno == ESRCH)
      #expect(Darwin.kill(replacement.processID, 0) == 0)
      if case .connected = await connection.state {
        // Expected after the replacement process is installed.
      } else {
        Issue.record("Replacement did not remain connected")
      }

      await connection.finishShutdown(
        id: firstShutdown.id,
        generation: firstShutdown.generation
      )
      #expect(await connection.process?.processID == replacement.processID)
      if case .connected = await connection.state {
        // A stale finalizer must not publish disconnected.
      } else {
        Issue.record("A stale finalizer clobbered the replacement")
      }

      await connection.disconnect()
      #expect(await terminator.invocationCount() == 2)
    }
  }

  @Test("Serializes concurrent writes and correlates every response")
  func serializesConcurrentRequests() async throws {
    let program =
      #"{ if (match($0, /\"id\":[0-9]+/)) { id = substr($0, RSTART + 5, RLENGTH - 5); print "{\"jsonrpc\":\"2.0\",\"id\":" id ",\"result\":{\"ok\":true}}"; fflush(); } }"#
    let connection = MCPStdioJSONRPCConnection(
      configuration: try configuration(program: program)
    )
    try await connection.connect()

    try await withThrowingTaskGroup(of: JSONValue.self) { group in
      for index in 0..<32 {
        group.addTask {
          try await connection.request(
            method: "test/concurrent",
            params: .object(["index": .integer(Int64(index))])
          )
        }
      }
      var count = 0
      for try await response in group {
        #expect(response == .object(["ok": .boolean(true)]))
        count += 1
      }
      #expect(count == 32)
    }
    await connection.disconnect()
  }

  @Test("Cancellation terminates the in-flight server process")
  func cancellationTerminatesProcess() async throws {
    let connection = MCPStdioJSONRPCConnection(
      configuration: try configuration(
        program: #"{ while (1) { } }"#,
        requestTimeoutMilliseconds: 2_000
      )
    )
    try await connection.connect()
    let task = Task {
      try await connection.request(method: "test/cancel", params: .object([:]))
    }
    try await Task.sleep(for: .milliseconds(20))
    task.cancel()

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
    await connection.disconnect()
  }

  @Test("Rejects an oversized unterminated stdout frame")
  func rejectsOversizedUnterminatedFrame() async throws {
    let connection = MCPStdioJSONRPCConnection(
      configuration: try configuration(
        program: #"{ for (i = 0; i < 2048; i++) printf "a"; fflush(); }"#
      )
    )
    try await connection.connect()

    await #expect(throws: MCPClientSessionError.limitExceeded) {
      try await connection.request(method: "test/oversized", params: .object([:]))
    }
    await connection.disconnect()
  }

  @Test("Drains stderr without publishing or retaining it as protocol data")
  func drainsStderr() async throws {
    let program =
      #"{ for (i = 0; i < 65536; i++) printf "e" > "/dev/stderr"; fflush("/dev/stderr"); print "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}"; fflush(); }"#
    let connection = MCPStdioJSONRPCConnection(
      configuration: try configuration(program: program)
    )
    try await connection.connect()

    let response = try await connection.request(
      method: "test/stderr",
      params: .object([:])
    )
    #expect(response == .object(["ok": .boolean(true)]))
    await connection.disconnect()
  }

  private func configuration(
    program: String,
    requestTimeoutMilliseconds: UInt64 = 2_000
  ) throws -> MCPServerConfiguration {
    try MCPServerConfiguration(
      serverID: "fixture",
      executableURL: URL(fileURLWithPath: "/usr/bin/awk"),
      arguments: [program],
      workingDirectory: URL(fileURLWithPath: "/"),
      environment: ["PATH": "/usr/bin:/bin"],
      requestTimeoutMilliseconds: requestTimeoutMilliseconds,
      shutdownGraceMilliseconds: 50,
      maximumMessageBytes: 1_024,
      maximumStderrBytes: 1_024
    )
  }

  private func mutableExecutableConfiguration(
    executableURL: URL
  ) throws -> MCPServerConfiguration {
    let program =
      #"index($0, "\"method\":\"initialize\"") { print "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"Fixture\",\"version\":\"1\"}}}"; fflush(); next }"#
    return try MCPServerConfiguration(
      serverID: "fixture",
      executableURL: executableURL,
      arguments: [program],
      workingDirectory: URL(fileURLWithPath: "/"),
      environment: ["PATH": "/usr/bin:/bin"],
      requestTimeoutMilliseconds: 2_000,
      shutdownGraceMilliseconds: 50,
      maximumMessageBytes: 4 * 1_024
    )
  }

  private func makeFixtureDirectory() throws -> URL {
    let directory = URL(
      fileURLWithPath: "/private/tmp/hex-mcp-executable-tests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    return directory
  }

  private func makeExecutable(_ url: URL) throws {
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: url.path
    )
  }

  private func writeAttackerExecutable(to url: URL, marker: URL) throws {
    try Data(attackerScript(marker: marker).utf8).write(to: url, options: .withoutOverwriting)
    try makeExecutable(url)
  }

  private func writeLegitimateExecutable(to url: URL) throws {
    let script = """
      #!/bin/sh
      while IFS= read -r request; do
        case "$request" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"Fixture","version":"1"}}}'
            ;;
        esac
      done
      """
    try Data(script.utf8).write(to: url, options: .withoutOverwriting)
    try makeExecutable(url)
  }

  private func writeSilentExecutable(to url: URL) throws {
    let script = """
      #!/bin/sh
      while IFS= read -r request; do
        :
      done
      """
    try Data(script.utf8).write(to: url, options: .withoutOverwriting)
    try makeExecutable(url)
  }

  private func makeRuntimeDependencyBundle(in directory: URL) throws -> (
    root: URL, executable: URL, dependency: URL, externalMarker: URL
  ) {
    let root = directory.appendingPathComponent("Fixture.app", isDirectory: true)
    let executableDirectory = root.appendingPathComponent("Contents/MacOS", isDirectory: true)
    let frameworkDirectory = root.appendingPathComponent("Contents/Frameworks", isDirectory: true)
    try FileManager.default.createDirectory(
      at: executableDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.createDirectory(
      at: frameworkDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let dependencySource = directory.appendingPathComponent("dependency.c")
    let externalDependencySource = directory.appendingPathComponent("external-dependency.c")
    let serverSource = directory.appendingPathComponent("server.c")
    let dependencyFramework = frameworkDirectory.appendingPathComponent(
      "MCPFixture.framework",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: dependencyFramework,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let dependency = dependencyFramework.appendingPathComponent("MCPFixture")
    let externalFrameworkDirectory = directory.appendingPathComponent(
      "External/MCPFixture.framework",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: externalFrameworkDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let externalDependency = externalFrameworkDirectory.appendingPathComponent("MCPFixture")
    let externalMarker = directory.appendingPathComponent("external-runtime-loaded")
    let executable = executableDirectory.appendingPathComponent("server")
    let response =
      #"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"Bundle Fixture\",\"version\":\"1\"}}}"#
    let dependencyProgram = """
      const char *mcp_fixture_initialize_response(void) {
        return "\(response)";
      }
      """
    let externalDependencyProgram = """
      #include <stdio.h>
      const char *mcp_fixture_initialize_response(void) {
        FILE *marker = fopen("\(externalMarker.path)", "w");
        if (marker != NULL) {
          fputs("external", marker);
          fclose(marker);
        }
        return "\(response)";
      }
      """
    let serverProgram = """
      #include <stdio.h>
      #include <string.h>
      extern const char *mcp_fixture_initialize_response(void);
      int main(void) {
        char line[8192];
        while (fgets(line, sizeof(line), stdin) != NULL) {
          if (strstr(line, "\\\"method\\\":\\\"initialize\\\"") != NULL) {
            fputs(mcp_fixture_initialize_response(), stdout);
            fputc('\\n', stdout);
            fflush(stdout);
          }
        }
        return 0;
      }
      """
    try Data(dependencyProgram.utf8).write(to: dependencySource, options: .withoutOverwriting)
    try Data(externalDependencyProgram.utf8).write(
      to: externalDependencySource,
      options: .withoutOverwriting
    )
    try Data(serverProgram.utf8).write(to: serverSource, options: .withoutOverwriting)
    try runFixtureCompiler(
      arguments: [
        "--sdk", "macosx", "clang", "-dynamiclib", dependencySource.path,
        "-Wl,-install_name,@rpath/MCPFixture.framework/MCPFixture", "-o", dependency.path,
      ]
    )
    try runFixtureCompiler(
      arguments: [
        "--sdk", "macosx", "clang", "-dynamiclib", externalDependencySource.path,
        "-Wl,-install_name,@rpath/MCPFixture.framework/MCPFixture", "-o",
        externalDependency.path,
      ]
    )
    try runFixtureCompiler(
      arguments: [
        "--sdk", "macosx", "clang", serverSource.path,
        "-F", frameworkDirectory.path, "-framework", "MCPFixture",
        "-Wl,-rpath,@executable_path/../SnapshotRuntime",
        "-Wl,-rpath,\(externalFrameworkDirectory.deletingLastPathComponent().path)",
        "-Wl,-rpath,@executable_path/../Frameworks", "-o", executable.path,
      ]
    )
    return (root, executable, dependency, externalMarker)
  }

  private func runFixtureCompiler(arguments: [String]) throws {
    let process = Process()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    let errorText = String(decoding: errorData.prefix(4_096), as: UTF8.self)
    try #require(
      process.terminationReason == .exit && process.terminationStatus == 0,
      "Fixture compiler failed: \(errorText)"
    )
  }

  private func attackerScript(marker: URL) -> String {
    "#!/bin/sh\nprintf attacker > '\(marker.path)'\n"
  }

  nonisolated private static func overwriteFile(atPath path: String, with data: Data) -> Bool {
    let descriptor = Darwin.open(path, O_WRONLY | O_TRUNC | O_CLOEXEC)
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }
    var offset = 0
    while offset < data.count {
      let written = data.withUnsafeBytes { bytes in
        Darwin.write(
          descriptor,
          bytes.baseAddress?.advanced(by: offset),
          data.count - offset
        )
      }
      if written < 0, errno == EINTR { continue }
      guard written > 0 else { return false }
      offset += written
    }
    return fsync(descriptor) == 0
  }

  nonisolated private static func appendByte(atPath path: String) -> Bool {
    let descriptor = Darwin.open(path, O_WRONLY | O_APPEND | O_CLOEXEC)
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }
    var byte = UInt8(ascii: "x")
    return Darwin.write(descriptor, &byte, 1) == 1 && fsync(descriptor) == 0
  }

  nonisolated private static func replaceFile(atPath path: String, with data: Data) -> Bool {
    guard Darwin.unlink(path) == 0 else { return false }
    let descriptor = Darwin.open(
      path,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      0o600
    )
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }
    var offset = 0
    while offset < data.count {
      let written = data.withUnsafeBytes { bytes in
        Darwin.write(
          descriptor,
          bytes.baseAddress?.advanced(by: offset),
          data.count - offset
        )
      }
      if written < 0, errno == EINTR { continue }
      guard written > 0 else { return false }
      offset += written
    }
    return fsync(descriptor) == 0
  }

  private func openDescriptorCount() throws -> Int {
    try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
  }

  private func catConfiguration() throws -> MCPServerConfiguration {
    try MCPServerConfiguration(
      serverID: "fixture",
      executableURL: URL(fileURLWithPath: "/bin/cat"),
      arguments: [],
      workingDirectory: URL(fileURLWithPath: "/"),
      environment: ["PATH": "/usr/bin:/bin"],
      requestTimeoutMilliseconds: 2_000,
      shutdownGraceMilliseconds: 50,
      maximumMessageBytes: 1_024,
      maximumStderrBytes: 1_024
    )
  }

  actor GatedProcessTerminator {
    private var firstTerminationStarted = false
    private var firstTerminationReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var invocations = 0

    func terminate(
      _ spawned: MCPSpawnedProcess,
      shutdownGraceMilliseconds: UInt64
    ) async {
      invocations += 1
      if invocations == 1 {
        firstTerminationStarted = true
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters {
          waiter.resume()
        }
        if !firstTerminationReleased {
          await withCheckedContinuation { continuation in
            releaseWaiter = continuation
          }
        }
      }
      await MCPStdioJSONRPCConnection.terminate(
        spawned,
        shutdownGraceMilliseconds: shutdownGraceMilliseconds
      )
    }

    func waitUntilFirstTerminationStarts() async {
      if firstTerminationStarted { return }
      await withCheckedContinuation { continuation in
        startWaiters.append(continuation)
      }
    }

    func releaseFirstTermination() {
      firstTerminationReleased = true
      releaseWaiter?.resume()
      releaseWaiter = nil
    }

    func invocationCount() -> Int {
      invocations
    }
  }
}
