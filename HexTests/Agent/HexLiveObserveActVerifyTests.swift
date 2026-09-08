import CryptoKit
import Foundation
import HexCore
import HexGatewayKit
import HexIPC
import HexMCP
import Testing

@testable import Hex

/// The signed test host connects to an explicitly selected canonical resident build.
/// It never activates its isolated helper or changes settings/privacy grants.
@Suite(
  "Live resident observe act verify", .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["HEX_RUN_LIVE_OAV"] == "1"),
  .timeLimit(.minutes(10))
)
struct HexLiveObserveActVerifyTests: Sendable {
  private static let nativeBundleID = "com.lunarmothstudios.Hex.ObserveActVerifyFixture"
  private static let nativeWindowTitle = "Hex Observe Act Verify Fixture"
  private static let nativeValue = "Hex native workflow verified"
  private static let nativeInitialValue = "Synthetic Hex qualification text"
  private static let nativeInitialResult = "No action has been applied"
  private static let receiptName = "hex-qualification-receipt.txt"
  private static let receiptText =
    "HEX_BROWSER_QUALIFICATION_RECEIPT\nlabel=Hex qualification draft\nsubmissions=1\n"

  @Test
  func workflowSelectionIsValid() throws {
    try Self.require(
      ["all", "browser", "native"].contains(
        ProcessInfo.processInfo.environment["HEX_OAV_WORKFLOW"] ?? "all"),
      "HEX_OAV_WORKFLOW must be browser, native, or all.")
  }

  @Test
  func skippedBatchReceiptKeepsAnnouncementWithoutInventingAStart() throws {
    let call = ToolCall(
      id: ToolCallID(rawValue: "qualification-skipped-call"),
      name: "mac_accessibility_action", arguments: [:])
    let announcement = AgentEvent.messageAppended(
      Message(role: .assistant, content: [.toolCall(call)]))
    let skipped = ToolResult(
      toolCallID: call.id, status: .failure, output: .object(["error": .string("not_executed")]),
      notExecutedReason: .runStopped)
    let parsed = try Self.receipts([announcement, .toolFinished(skipped)])
    let receipt = try #require(parsed.first)
    #expect(receipt.call == call)
    #expect(receipt.startIndex == nil)
    #expect(!receipt.started(after: -1))
    #expect(throws: QualificationError.self) {
      try Self.receipts([.toolFinished(skipped)])
    }
    let uncorrelatedSuccess = ToolResult(toolCallID: call.id, status: .success, output: .null)
    #expect(throws: QualificationError.self) {
      try Self.receipts([announcement, .toolFinished(uncorrelatedSuccess)])
    }
    let unknown = ToolResult(toolCallID: call.id, status: .failure, output: .null)
    #expect(throws: QualificationError.self) {
      try Self.receipts([announcement, .toolFinished(unknown)])
    }
  }

  @Test(
    .enabled(
      if: ["all", "native"].contains(
        ProcessInfo.processInfo.environment["HEX_OAV_WORKFLOW"] ?? "all")))
  func nativeFixtureWorkflow() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["HEX_OAV_NATIVE_BUNDLE_ID"] == Self.nativeBundleID,
      let rawPID = environment["HEX_OAV_NATIVE_PID"], let pid = Int64(rawPID),
      (1...Int64(Int32.max)).contains(pid),
      let rawWindow = environment["HEX_OAV_NATIVE_WINDOW_ID"], let window = Int64(rawWindow),
      (1...Int64(UInt32.max)).contains(window)
    else { throw QualificationError.invalidFixture }
    let probeOnly = environment["HEX_OAV_PROBE_ONLY"] == "1"
    let identity = """
      Use only the disposable local app with exact bundle ID \(Self.nativeBundleID), PID \(pid),
      window ID \(window), titled \(Self.nativeWindowTitle). For screen evidence use managed see
      with app_target=PID:\(pid), window_id=\(window), and background capture. Do not inspect
      unrelated windows, change privacy grants, or run shell commands/scripts.
      """
    let prompt =
      probeOnly
      ? identity + """

        This is a read-only probe. Use mac_accessibility_snapshot and managed see or scoped
        window-list tools only. Do not act on any control. Report synthetic text and exact blockers.
        """
      : identity + """

        First take mac_accessibility_snapshot and confirm the initial field is exactly
        \(Self.nativeInitialValue) and the result is exactly \(Self.nativeInitialResult).
        If either differs, stop before any input and report that a fresh fixture is required.
        Do not reset or change an already-used fixture to make it appear fresh.
        Complete the harmless workflow with exactly two built-in mac_accessibility_action calls:
        first action=set_value on the observed text field, value=\(Self.nativeValue); then, after
        a new mac_accessibility_snapshot, action=press on Apply synthetic change exactly once.
        Use only mac_accessibility_snapshot, mac_accessibility_action, managed see, and scoped
        window-list tools. Do not substitute managed screen input or add a focus action.
        Each action needs its own current native observation_id. Re-observe after each action.
        After the press, verify the field and Applied synthetic change 1 using a fresh semantic
        snapshot, then capture and inspect a fresh see image of this same PID/window.
        Do not repeat a possibly dispatched action. Report HEX_NATIVE_WORKFLOW_VERIFIED only
        after both post-action semantic and image evidence; otherwise report the concrete blocker.
        """
    let events = try await run(
      prompt: prompt, stage: probeOnly ? "native-probe" : "native", allowsBlockedRun: probeOnly)
    let receipts = try Self.receipts(events)
    #expect(!receipts.isEmpty)
    for receipt in receipts {
      let call = receipt.call
      switch call.name {
      case "mac_accessibility_snapshot", "mac_accessibility_action":
        try Self.require(
          call.arguments["bundle_id"] == .string(Self.nativeBundleID),
          "Native call targeted another app.")
        try Self.require(
          !probeOnly || call.name != "mac_accessibility_action",
          "Read-only probe attempted an action.")
      case "mcp_8_peekaboo_see", "mcp_8_peekaboo_inspect_ui":
        try Self.require(
          call.arguments["app_target"] == .string("PID:\(pid)")
            && call.arguments["window_id"] == .integer(window),
          "Screen observation targeted another window.")
      case "mcp_8_peekaboo_window":
        try Self.require(
          call.arguments["action"] == .string("list")
            && (call.arguments["app"] == .string("PID:\(pid)")
              || call.arguments["app"] == .string(Self.nativeBundleID)),
          "Window listing was not scoped to the fixture.")
      default: throw QualificationError.missingEvidence("Unexpected native tool: \(call.name).")
      }
    }
    guard !probeOnly else { return }
    try Self.verifyNative(receipts, events: events, pid: pid, window: window)
  }

  @Test(
    .enabled(
      if: ["all", "browser"].contains(
        ProcessInfo.processInfo.environment["HEX_OAV_WORKFLOW"] ?? "all")
        && ProcessInfo.processInfo.environment["HEX_OAV_PROBE_ONLY"] != "1"))
  func browserFixtureWorkflow() async throws {
    let environment = ProcessInfo.processInfo.environment
    let rawURL = try #require(environment["HEX_OAV_BROWSER_URL"])
    guard let url = URL(string: rawURL), url.scheme == "http", url.host == "127.0.0.1",
      let port = url.port, (1...65_535).contains(port), url.user == nil, url.password == nil,
      url.query == nil, url.fragment == nil, url.path == "/" || url.path.isEmpty
    else { throw QualificationError.invalidFixture }
    let stateDirectory = try Self.temporaryDirectory(
      environment["HEX_OAV_BROWSER_STATE_DIR"], create: false)
    let recordedPort = try String(
      contentsOf: stateDirectory.appendingPathComponent("port.txt"), encoding: .utf8)
    try Self.require(
      Int(recordedPort) == port, "Fixture directory does not own the requested loopback port.")
    let initial = try Self.readObject(stateDirectory.appendingPathComponent("state.json"))
    try Self.require(
      Self.replaying
        || initial["submission_count"] == .integer(0) && initial["download_count"] == .integer(0),
      "Use a fresh browser fixture without prior effects.")
    let configuration = try await HexGatewayResidentConfiguration.loadPersisted()
    let layout = try #require(configuration.managedToolLayout)
    let downloadURL = layout.playwrightOutputURL.appendingPathComponent(Self.receiptName)
      .standardizedFileURL
    let startedAt: Date
    if Self.replaying {
      let directory = try Self.temporaryDirectory(
        environment["HEX_OAV_EVIDENCE_DIR"], create: false)
      startedAt = try #require(
        directory.appendingPathComponent("resident-browser-identity.json")
          .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    } else {
      startedAt = Date()
    }
    let prompt = """
      Complete the harmless local browser fixture at \(url.absoluteString) using Hex's managed
      Playwright tools. Take a full inline browser_snapshot first, without target, filename, or
      depth; use each fresh hex_observation_id for one action. Open draft form, click Refresh
      form controls, re-observe the rerendered controls,
      and set Draft label to exactly Hex qualification draft. Submit Save local draft once.
      Re-observe and verify Draft saved, the exact label, and Total submissions: 1. Download
      Download draft receipt once. Require a completed download event, then read the actual file
      \(downloadURL.path) using process_run with executable=/bin/cat and arguments containing
      only that exact absolute path. Do not run a shell, browser JavaScript, or any other process.
      Use only browser_snapshot, browser_navigate, browser_click, browser_type, browser_fill_form,
      browser_tabs, browser_wait_for, and the one exact cat read. Keep the same owned tab through
      the form workflow. Do not visit unrelated sites, act on other apps, or repeat a possibly
      dispatched submit. Observe after each action and use only fresh element references.
      Report HEX_BROWSER_WORKFLOW_VERIFIED only after the final page and actual downloaded
      contents are verified. If blocked, state the actual blocker.
      """
    let events = try await run(prompt: prompt, stage: "browser")
    let receipts = try Self.receipts(events)
    try Self.verifyBrowserScope(receipts, endpoint: url, downloadURL: downloadURL)
    let confirmationURL = url.appendingPathComponent("result/1").absoluteString
    let confirmation = try #require(
      receipts.first {
        $0.call.name == "mcp_10_playwright_browser_snapshot" && $0.result.status == .success
          && Self.resultText($0.result).contains("- Page URL: \(confirmationURL)")
          && Self.resultText($0.result).contains("Saved local draft: Hex qualification draft")
          && Self.resultText($0.result).contains("Total submissions: 1")
      })
    let download = try #require(
      receipts.first {
        $0.started(after: confirmation.finishIndex) && $0.result.status == .success
          && $0.call.name.hasPrefix("mcp_10_playwright_")
          && Self.resultText($0.result).contains("Downloaded file \(Self.receiptName) to \"")
      })
    let reading = try #require(
      receipts.first {
        $0.started(after: download.finishIndex) && $0.call.name == "process_run"
          && $0.result.status == .success && Self.resultText($0.result).contains(Self.receiptText)
      })
    try Self.require(
      Self.hasMarker("HEX_BROWSER_WORKFLOW_VERIFIED", after: reading.finishIndex, events: events),
      "No final report after reading the downloaded receipt.")
    let state = try Self.readObject(stateDirectory.appendingPathComponent("state.json"))
    try Self.require(
      state["submission_count"] == .integer(1) && state["download_count"] == .integer(1)
        && state["label"] == .string("Hex qualification draft")
        && state["observed_generation"] == .integer(1),
      "Fixture counters, label or rerender do not match the requested journey.")
    let journal = try String(
      contentsOf: stateDirectory.appendingPathComponent("requests.jsonl"), encoding: .utf8)
    let requests = try journal.split(separator: "\n").map {
      try JSONDecoder().decode([String: JSONValue].self, from: Data($0.utf8))
    }
    try Self.require(
      requests.filter { $0["method"] == .string("POST") && $0["path"] == .string("/submit") }.count
        == 1,
      "Expected exactly one recorded form submission.")
    try Self.require(
      requests.filter { $0["method"] == .string("GET") && $0["path"] == .string("/receipt.txt") }
        .count == 1,
      "Expected exactly one recorded receipt download.")
    let attributes = try downloadURL.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
    try Self.require(
      attributes.isRegularFile == true && attributes.isSymbolicLink != true,
      "Downloaded receipt is not a regular file.")
    let modified = try #require(attributes.contentModificationDate)
    try Self.require(modified >= startedAt, "Downloaded receipt predates this qualification run.")
    try Self.require(
      try String(contentsOf: downloadURL, encoding: .utf8) == Self.receiptText,
      "Actual downloaded contents differ from the expected fixture receipt.")
    try Self.write(
      .object([
        "state_directory": .string(stateDirectory.path), "download_path": .string(downloadURL.path),
        "state": .object(state), "submission_posts": .integer(1), "receipt_downloads": .integer(1),
      ]), name: "resident-browser-fixture-evidence.json")
  }

  private func run(prompt: String, stage: String, allowsBlockedRun: Bool = false) async throws
    -> [AgentEvent]
  {
    _ = try Self.temporaryDirectory(
      ProcessInfo.processInfo.environment["HEX_OAV_EVIDENCE_DIR"], create: true)
    let configuration = try await HexGatewayResidentConfiguration.loadPersisted()
    guard configuration.authorizationMode == .fullAccess else {
      throw QualificationError.requiresExistingFullAccess
    }
    let canonical = try Self.canonicalApp()
    let gateway = HexGatewayClient(
      transport: XPCGatewayTransport(machServiceName: configuration.machServiceName))
    let adapter = HexGatewayClientAdapter(
      client: gateway,
      authorizationTransport: HexGatewayAuthorizationDecisionAdapter(client: gateway),
      expectedExecutableID: canonical.executableID)
    let client = HexLiveAgentClient(
      configuration: HexDeveloperConfiguration(environment: ProcessInfo.processInfo.environment),
      route: .residentXPC(machServiceName: configuration.machServiceName),
      initialGatewayAdapter: adapter)
    if Self.replaying {
      let directory = try Self.temporaryDirectory(
        ProcessInfo.processInfo.environment["HEX_OAV_EVIDENCE_DIR"], create: false)
      let identity = try Self.readObject(
        directory.appendingPathComponent("resident-\(stage)-identity.json"))
      try Self.require(
        identity["canonical_app_path"] == .string(canonical.url.path)
          && identity["expected_executable_id"] == .string(canonical.executableID.uuidString)
          && identity["stage"] == .string(stage),
        "Saved run belongs to another executable or stage.")
      guard case .string(let rawID) = identity["run_id"], let uuid = UUID(uuidString: rawID) else {
        throw QualificationError.invalidFixture
      }
      let events = try JSONDecoder().decode(
        [AgentEvent].self,
        from: Data(contentsOf: directory.appendingPathComponent("resident-\(stage)-events.json")))
      try Self.require(
        events.contains { if case .runCompleted = $0 { true } else { false } },
        "Saved run did not complete.")
      do {
        _ = try await client.connect()
        let hydrated = try await Self.hydrate(
          events, client: client, runID: AgentRunID(rawValue: uuid))
        try await client.disconnect()
        return hydrated
      } catch {
        await client.resetResidentGatewayConnection()
        throw error
      }
    }
    let runID = AgentRunID()
    try Self.write(
      .object([
        "canonical_app_path": .string(canonical.url.path),
        "expected_executable_id": .string(canonical.executableID.uuidString),
        "run_id": .string(runID.rawValue.uuidString), "stage": .string(stage),
      ]), name: "resident-\(stage)-identity.json")
    do {
      let connection = try await Self.withTimeout(seconds: 15, stage: "canonical handshake") {
        try await client.connect()
      }
      guard connection.response.activeRun == nil else { throw QualificationError.residentBusy }
      let events = try await Self.withTimeout(seconds: allowsBlockedRun ? 120 : 360, stage: stage) {
        let response = try await client.startRun(
          GatewayStartRunRequest(
            runID: runID, modelID: ModelID(rawValue: configuration.modelID),
            initialMessages: [Message(role: .user, content: [.text(prompt)])],
            toolChoice: .automatic))
        guard case .started(let invocationID) = response.disposition else {
          throw QualificationError.residentBusy
        }
        try Self.write(
          .object([
            "run_id": .string(runID.rawValue.uuidString),
            "invocation_id": .string(invocationID.rawValue.uuidString),
            "expected_executable_id": .string(canonical.executableID.uuidString),
          ]), name: "resident-\(stage)-invocation.json")
        var events: [AgentEvent] = []
        for try await envelope in try await client.eventRecords(
          for: runID, invocationID: invocationID)
        {
          guard try await client.shouldApply(envelope) else { continue }
          let event = envelope.record.event
          switch event {
          case .toolStarted, .toolFinished, .messageAppended, .runCompleted, .runFailed,
            .runCancelled:
            events.append(event)
            try Self.save(events, stage: stage)
          default: break
          }
          try await client.acknowledge(envelope)
        }
        return events
      }
      try Self.require(
        events.contains {
          if case .runCompleted = $0 { return true }
          if allowsBlockedRun, case .runFailed = $0 { return true }
          return false
        }, "Resident run did not reach the required terminal outcome.")
      let hydrated = try await Self.hydrate(events, client: client, runID: runID)
      try await Self.withTimeout(seconds: 10, stage: "disconnect") { try await client.disconnect() }
      return hydrated
    } catch {
      // A suite timeout cancels this task. A fresh task permits cancellation-checked client calls.
      // Re-handshake also finds an admitted run whose start response was lost.
      await Task { await Self.cancelOwnedRun(client: client, runID: runID, stage: stage) }.value
      throw error
    }
  }

  /// Rechecks immutable completed evidence without starting a run or repeating fixture inputs.
  private static var replaying: Bool {
    ProcessInfo.processInfo.environment["HEX_OAV_REPLAY_COMPLETED"] == "1"
  }

  private static func hydrate(_ events: [AgentEvent], client: HexLiveAgentClient, runID: AgentRunID)
    async throws -> [AgentEvent]
  {
    let calls = try receipts(events)
    var hydrated = events
    for receipt in calls {
      let result = receipt.result
      let stored = field(result, "stored_tool_result") == .boolean(true)
      let rawProcess = receipt.call.name == "process_run" && result.status == .success
      guard stored || rawProcess else { continue }
      let candidates = result.artifacts.filter {
        $0.mediaType == (stored ? "application/json" : "application/octet-stream")
      }
      try require(candidates.count == 1, "Expected one authoritative output artifact.")
      let reference = try #require(candidates.first)
      try require(
        reference.runID == runID && reference.toolCallID == result.toolCallID
          && reference.isComplete && reference.byteCount > 0 && reference.byteCount <= 1_048_576,
        "Artifact ownership or completeness does not match the completed call.")
      var data = Data()
      while Int64(data.count) < reference.byteCount {
        let response = try await client.readArtifact(
          GatewayArtifactReadRequest(
            reference: reference, offset: Int64(data.count), maximumBytes: 16_384))
        try require(
          response.reference == reference && response.offset == Int64(data.count)
            && !response.data.isEmpty
            && Int64(data.count + response.data.count) <= reference.byteCount,
          "Artifact range response is inconsistent.")
        data.append(response.data)
      }
      let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      try require(digest == reference.sha256, "Artifact digest differs from its immutable receipt.")
      if stored {
        let original = try JSONDecoder().decode(ToolResult.self, from: data)
        try require(
          original.toolCallID == result.toolCallID && original.status == result.status
            && original.requiresUserAttention == result.requiresUserAttention
            && original.notExecutedReason == result.notExecutedReason,
          "Stored result contradicts the event receipt.")
        hydrated[receipt.finishIndex] = .toolFinished(original)
      } else {
        let text = try #require(String(data: data, encoding: .utf8))
        hydrated[receipt.finishIndex] = .toolFinished(
          ToolResult(
            toolCallID: result.toolCallID, status: result.status, output: result.output,
            content: result.content + [.text(text)], artifacts: result.artifacts,
            requiresUserAttention: result.requiresUserAttention,
            notExecutedReason: result.notExecutedReason))
      }
    }
    return hydrated
  }

  private static func cancelOwnedRun(client: HexLiveAgentClient, runID: AgentRunID, stage: String)
    async
  {
    var status = "ownership_unverified"
    do {
      try await withTimeout(seconds: 15, stage: "owned-run cleanup") {
        await client.resetResidentGatewayConnection()
        let connection = try await client.connect()
        if let active = connection.response.activeRun, active.runID == runID {
          let response = try await client.cancelRun(
            GatewayCancelRunRequest(runID: runID, invocationID: active.invocationID))
          try write(
            .object([
              "run_id": .string(runID.rawValue.uuidString),
              "invocation_id": .string(active.invocationID.rawValue.uuidString),
              "disposition": .string(response.disposition.rawValue),
            ]), name: "resident-\(stage)-cancellation.json")
        }
        try await client.disconnect()
      }
      status = "owned_run_checked_and_connection_closed"
    } catch {
      await client.resetResidentGatewayConnection()
    }
    try? write(
      .object(["run_id": .string(runID.rawValue.uuidString), "status": .string(status)]),
      name: "resident-\(stage)-cleanup.json")
  }

  private static func withTimeout<Value: Sendable>(
    seconds: Int, stage: String, operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await Task.sleep(for: .seconds(seconds))
        throw QualificationError.timedOut(stage)
      }
      defer { group.cancelAll() }
      guard let value = try await group.next() else { throw QualificationError.timedOut(stage) }
      return value
    }
  }

  private static func canonicalApp() throws -> (url: URL, executableID: UUID) {
    let path = try #require(ProcessInfo.processInfo.environment["HEX_OAV_CANONICAL_APP_PATH"])
    guard path.hasPrefix("/") else { throw QualificationError.invalidFixture }
    let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    guard url.lastPathComponent == "Hex.app",
      Bundle(url: url)?.bundleIdentifier == "com.lunarmothstudios.Hex",
      try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
      let executableID = try GatewayExecutableIdentity.executableID(
        at: url.appendingPathComponent(HexGatewayServiceIdentity.bundledExecutablePath))
    else { throw QualificationError.invalidFixture }
    return (url, executableID)
  }

  private static func temporaryDirectory(_ path: String?, create: Bool) throws -> URL {
    guard let path, path.hasPrefix("/") else { throw QualificationError.invalidFixture }
    let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
      .resolvingSymlinksInPath()
    let roots = [
      FileManager.default.temporaryDirectory,
      URL(fileURLWithPath: "/private/tmp", isDirectory: true),
    ]
    .map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
    guard roots.contains(where: { directory.path.hasPrefix($0 + "/") }) else {
      throw QualificationError.invalidFixture
    }
    if create {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    }
    guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
      throw QualificationError.invalidFixture
    }
    return directory
  }

  private static func save(_ events: [AgentEvent], stage: String) throws {
    let directory = try temporaryDirectory(
      ProcessInfo.processInfo.environment["HEX_OAV_EVIDENCE_DIR"], create: false)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(events).write(
      to: directory.appendingPathComponent("resident-\(stage)-events.json"), options: .atomic)
  }

  private static func write(_ value: JSONValue, name: String) throws {
    let directory = try temporaryDirectory(
      ProcessInfo.processInfo.environment["HEX_OAV_EVIDENCE_DIR"], create: false)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
  }

  private static func readObject(_ url: URL) throws -> [String: JSONValue] {
    let data = try Data(contentsOf: url)
    guard data.count <= 1_024 * 1_024 else { throw QualificationError.invalidFixture }
    return try JSONDecoder().decode([String: JSONValue].self, from: data)
  }

  private static func verifyNative(
    _ receipts: [Receipt], events: [AgentEvent], pid: Int64, window: Int64
  ) throws {
    let actions = receipts.filter { $0.call.name == "mac_accessibility_action" }
    try require(actions.count == 2, "Expected exactly set_value and press receipts.")
    let setting = actions[0]
    let pressing = actions[1]
    _ = try #require(setting.startIndex)
    _ = try #require(pressing.startIndex)
    try require(
      setting.call.arguments["action"] == .string("set_value")
        && setting.call.arguments["value"] == .string(nativeValue),
      "First native action was not the exact field change.")
    try require(
      pressing.call.arguments["action"] == .string("press")
        && pressing.started(after: setting.finishIndex),
      "Second native action was not a subsequent single press.")
    for action in actions {
      try require(
        action.result.status == .success && field(action.result, "dispatched") == .boolean(true)
          && field(action.result, "outcome_verified") == .boolean(false),
        "Missing native dispatch-only receipt.")
      try require(
        field(action.result, "observation_id") == action.call.arguments["observation_id"],
        "Native action lost observation correlation.")
    }
    let initial = try observationUsed(by: setting, receipts: receipts, pid: pid)
    let input = try element(initial.result, identifier: "hex-fixture-text")
    let initialResult = try element(initial.result, identifier: "hex-fixture-result")
    try require(
      input["value"] == .string(nativeInitialValue)
        && initialResult["value"] == .string(nativeInitialResult),
      "The observation authorizing the first action did not show a pristine native fixture.")
    try require(
      field(setting.result, "path") == input["path"]
        && field(setting.result, "window_reference") == input["window_reference"],
      "set_value targeted another element/window.")
    let between = try observationUsed(by: pressing, receipts: receipts, pid: pid)
    try require(
      between.started(after: setting.finishIndex), "No fresh snapshot between native actions.")
    let changed = try element(between.result, identifier: "hex-fixture-text")
    try require(
      changed["value"] == .string(nativeValue), "Fresh observation did not verify the field change."
    )
    let button = try element(between.result, identifier: "hex-fixture-apply")
    try require(
      field(pressing.result, "path") == button["path"]
        && field(pressing.result, "window_reference") == button["window_reference"],
      "press targeted another element/window.")
    let post = try #require(
      receipts.first {
        $0.started(after: pressing.finishIndex) && isNativeSnapshot($0, pid: pid)
          && (try? element($0.result, identifier: "hex-fixture-result")["value"])
            == .string("Applied synthetic change 1")
      })
    let postField = try element(post.result, identifier: "hex-fixture-text")
    let postResult = try element(post.result, identifier: "hex-fixture-result")
    try require(
      postField["value"] == .string(nativeValue) && postField["window_reference"] != nil
        && postField["window_reference"] == postResult["window_reference"],
      "Post-press text is not in the same window.")
    let elements = try nativeElements(post.result)
    try require(
      elements.contains {
        $0["role"] == .string("AXWindow") && $0["title"] == .string(nativeWindowTitle)
          && $0["window_reference"] == postResult["window_reference"]
      }, "No matching fixture window in post-press semantic evidence.")
    let image = try #require(
      receipts.first {
        $0.started(after: post.finishIndex) && $0.call.name == "mcp_8_peekaboo_see"
          && $0.result.status == .success
          && $0.call.arguments["app_target"] == .string("PID:\(pid)")
          && $0.call.arguments["window_id"] == .integer(window)
          && field($0.result, "hex_observed_pid") == .integer(pid)
          && field($0.result, "hex_observed_window_id") == .integer(window)
          && $0.result.content.contains { if case .image = $0 { true } else { false } }
      })
    try require(
      hasMarker("HEX_NATIVE_WORKFLOW_VERIFIED", after: image.finishIndex, events: events),
      "No completion report after the exact-window post-action screenshot.")
  }

  private static func verifyBrowserScope(_ receipts: [Receipt], endpoint: URL, downloadURL: URL)
    throws
  {
    let tools: Set<String> = [
      "browser_snapshot", "browser_navigate", "browser_click", "browser_type",
      "browser_fill_form", "browser_tabs", "browser_wait_for",
    ]
    for receipt in receipts {
      let call = receipt.call
      if call.name == "process_run" {
        try require(
          call.arguments["executable"] == .string("/bin/cat")
            && call.arguments["arguments"] == .array([.string(downloadURL.path)]),
          "Process exceeded the exact receipt read.")
      } else {
        let prefix = "mcp_10_playwright_"
        try require(
          call.name.hasPrefix(prefix) && tools.contains(String(call.name.dropFirst(prefix.count))),
          "Unexpected browser qualification tool: \(call.name).")
        // The adapter ignores url for tab list/select/close. An empty optional URL on a
        // tab-list call is not a navigation attempt and must not hide the actual run blocker.
        let navigates =
          call.name == prefix + "browser_navigate"
          || (call.name == prefix + "browser_tabs" && call.arguments["action"] == .string("new")
            && call.arguments["url"] != nil && call.arguments["url"] != .string(""))
        if navigates {
          guard case .string(let raw) = call.arguments["url"],
            let url = URL(string: raw), url.scheme == endpoint.scheme,
            url.host == endpoint.host,
            url.port == endpoint.port, url.user == nil, url.password == nil
          else {
            throw QualificationError.missingEvidence("Navigation left the local browser fixture.")
          }
        }
      }
    }
  }

  private static func receipts(_ events: [AgentEvent]) throws -> [Receipt] {
    var announced: [ToolCallID: ToolCall] = [:]
    var starts: [ToolCallID: (ToolCall, Int)] = [:]
    var completed: Set<ToolCallID> = []
    var result: [Receipt] = []
    for (index, event) in events.enumerated() {
      switch event {
      case .messageAppended(let message) where message.role == .assistant:
        for content in message.content {
          guard case .toolCall(let call) = content else { continue }
          try require(announced[call.id] == nil, "Duplicate announced call identity.")
          announced[call.id] = call
        }
      case .toolStarted(let call):
        try require(
          starts[call.id] == nil && !completed.contains(call.id),
          "Duplicate started call identity.")
        if let original = announced[call.id] {
          try require(original == call, "Started call differs from its announced arguments.")
        }
        starts[call.id] = (call, index)
      case .toolFinished(let receipt):
        try require(
          completed.insert(receipt.toolCallID).inserted, "Duplicate finished call identity.")
        if let started = starts.removeValue(forKey: receipt.toolCallID) {
          result.append(
            Receipt(call: started.0, result: receipt, startIndex: started.1, finishIndex: index))
        } else {
          // Runtime cleanup settles announced calls skipped after a blocker. Preserve their
          // scope and receipt without inventing an execution start or dispatch evidence.
          guard receipt.notExecutedReason != nil, receipt.hasValidNonExecutionMetadata,
            let call = announced[receipt.toolCallID]
          else {
            throw QualificationError.missingEvidence(
              "Finished receipt has neither a matching start nor a valid unexecuted announcement.")
          }
          result.append(Receipt(call: call, result: receipt, startIndex: nil, finishIndex: index))
        }
      default: break
      }
    }
    return result
  }

  private static func observationUsed(by action: Receipt, receipts: [Receipt], pid: Int64) throws
    -> Receipt
  {
    let actionStart = try #require(action.startIndex)
    return try #require(
      receipts.last {
        $0.startIndex != nil && $0.finishIndex < actionStart && isNativeSnapshot($0, pid: pid)
          && field($0.result, "observation_id") == action.call.arguments["observation_id"]
      })
  }

  private static func isNativeSnapshot(_ receipt: Receipt, pid: Int64) -> Bool {
    guard receipt.call.name == "mac_accessibility_snapshot", receipt.result.status == .success,
      receipt.call.arguments["bundle_id"] == .string(nativeBundleID),
      case .object(let app) = field(receipt.result, "application")
    else { return false }
    return app["bundle_id"] == .string(nativeBundleID) && app["process_id"] == .integer(pid)
  }

  private static func nativeElements(_ result: ToolResult) throws -> [[String: JSONValue]] {
    guard case .array(let elements) = field(result, "elements") else {
      throw QualificationError.missingEvidence("Native observation omitted elements.")
    }
    return elements.compactMap { if case .object(let value) = $0 { value } else { nil } }
  }

  private static func element(_ result: ToolResult, identifier: String) throws -> [String:
    JSONValue]
  {
    let matches = try nativeElements(result).filter { $0["identifier"] == .string(identifier) }
    try require(matches.count == 1, "Native element missing or ambiguous: \(identifier).")
    return matches[0]
  }

  private static func hasMarker(_ marker: String, after index: Int, events: [AgentEvent]) -> Bool {
    events.enumerated().contains { offset, event in
      guard offset > index, case .messageAppended(let message) = event, message.role == .assistant
      else { return false }
      return message.content.contains {
        if case .text(let text) = $0 { text.contains(marker) } else { false }
      }
    }
  }

  private static func field(_ result: ToolResult, _ key: String) -> JSONValue? {
    guard case .object(let output) = result.output else { return nil }
    return output[key]
  }

  private static func resultText(_ result: ToolResult) -> String {
    result.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(
      separator: "\n")
      + "\n" + strings(result.output).joined(separator: "\n")
  }

  private static func strings(_ value: JSONValue) -> [String] {
    switch value {
    case .string(let text): [text]
    case .array(let values): values.flatMap(strings)
    case .object(let object): object.values.flatMap(strings)
    default: []
    }
  }

  private static func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw QualificationError.missingEvidence(message) }
  }

  private struct Receipt: Sendable {
    let call: ToolCall
    let result: ToolResult
    let startIndex: Int?
    let finishIndex: Int

    func started(after index: Int) -> Bool {
      guard let startIndex else { return false }
      return startIndex > index
    }
  }

  private enum QualificationError: Error {
    case invalidFixture
    case residentBusy
    case requiresExistingFullAccess
    case timedOut(String)
    case missingEvidence(String)
  }
}
