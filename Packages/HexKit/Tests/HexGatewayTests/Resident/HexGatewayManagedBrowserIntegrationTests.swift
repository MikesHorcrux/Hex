import Foundation
import HexCore
import HexGatewayKit
import HexMCP
import Testing

@Suite(
  "Managed browser local workflow integration", .serialized,
  .enabled(
    if: ProcessInfo.processInfo.environment["HEX_RUN_BROWSER_WORKFLOW_INTEGRATION"] == "1",
    "Set HEX_RUN_BROWSER_WORKFLOW_INTEGRATION=1 and HEX_MANAGED_TOOLS_ROOT to use the installed browser."
  ), .timeLimit(.minutes(3))
)
@MainActor
struct HexGatewayManagedBrowserIntegrationTests {
  @Test
  func navigatesRecoversRerenderSubmitsOnceVerifiesDownloadAndKeepsTabOwnership() async throws {
    let fixture = try Fixture()
    do {
      try await fixture.start()
      let blank = try await fixture.observe()
      #expect(blank.text.contains("about:blank"))
      _ = try await fixture.act(
        "browser_navigate", ["url": .string(fixture.endpoint.absoluteString)],
        observation: blank)
      let landing = try await fixture.observe()
      #expect(landing.text.contains("Local browser workflow"))
      _ = try await fixture.act(
        "browser_click", ["target": .string(try landing.reference("Open draft form"))],
        observation: landing)
      let beforeRerender = try await fixture.observe()
      let oldSubmit = try beforeRerender.reference("Save local draft")

      // Replace the actual DOM independently after the observation. The host token is current,
      // so this reaches the real adapter's pre-input stale-ref rejection, not just the host guard.
      try await fixture.rerenderAndWait()
      let stale = try await fixture.act(
        "browser_click", ["target": .string(oldSubmit)],
        observation: beforeRerender)
      #expect(Fixture.field(stale, "error") == .string("browser_reference_stale"))
      #expect(!stale.requiresUserAttention)
      #expect(try fixture.state()["submission_count"] == .integer(0))

      let current = try await fixture.observe()
      #expect(current.text.contains("Form refreshed. Use current controls."))
      #expect(try current.reference("Save local draft") != oldSubmit)
      _ = try await fixture.act(
        "browser_type",
        [
          "target": .string(try current.reference("Draft label")),
          "text": .string("Hex qualification draft"),
        ], observation: current)
      let filled = try await fixture.observe()
      let submitted = try await fixture.act(
        "browser_click",
        [
          "target": .string(try filled.reference("Save local draft"))
        ], observation: filled)
      #expect(submitted.status == .success)
      #expect(Fixture.field(submitted, "hex_browser_verification_required") == .boolean(true))
      let saved = try await fixture.observe()
      #expect(saved.text.contains("Draft saved"))
      #expect(saved.text.contains("Saved local draft: Hex qualification draft"))
      #expect(saved.text.contains("Total submissions: 1"))
      #expect(try fixture.state()["submission_count"] == .integer(1))

      let download = try await fixture.act(
        "browser_click",
        [
          "target": .string(try saved.reference("Download draft receipt"))
        ], observation: saved)
      var afterDownload = try await fixture.observe()
      var downloadEvidence = Fixture.text(download) + "\n" + afterDownload.text
      let downloadDeadline = ContinuousClock.now.advanced(by: .seconds(5))
      while !downloadEvidence.contains("Downloaded file hex-qualification-receipt.txt"),
        ContinuousClock.now < downloadDeadline
      {
        try await Task.sleep(for: .milliseconds(50))
        afterDownload = try await fixture.observe()
        downloadEvidence += "\n" + afterDownload.text
      }
      #expect(downloadEvidence.contains("Downloaded file hex-qualification-receipt.txt"))
      let downloaded = try String(
        contentsOf: fixture.outputURL.appendingPathComponent(
          "hex-qualification-receipt.txt"), encoding: .utf8)
      #expect(
        downloaded
          == "HEX_BROWSER_QUALIFICATION_RECEIPT\nlabel=Hex qualification draft\nsubmissions=1\n")

      _ = try await fixture.act(
        "browser_tabs",
        [
          "action": .string("new"),
          "url": .string(fixture.endpoint.appendingPathComponent("details").absoluteString),
        ], observation: afterDownload)
      let secondTab = try await fixture.observe()
      #expect(secondTab.text.contains("HEX_REFERENCE_PAGE_OK"))
      #expect(secondTab.text.contains("- 0: [Draft saved]"))
      #expect(secondTab.text.contains("- 1: (current) [Reference page]"))
      _ = try await fixture.act(
        "browser_tabs", ["action": .string("select"), "index": .integer(0)],
        observation: secondTab)
      let originalTab = try await fixture.observe()
      #expect(originalTab.text.contains("Saved local draft: Hex qualification draft"))
      _ = try await fixture.act(
        "browser_tabs", ["action": .string("close"), "index": .integer(1)],
        observation: originalTab)
      let final = try await fixture.observe()
      #expect(final.text.contains("Total submissions: 1"))
      #expect(try fixture.state()["download_count"] == .integer(1))
      #expect(try fixture.submissionRequestCount() == 1)

      // A new managed connection has an empty isolated context and cannot reuse the previous token.
      try await fixture.restartBrowser()
      let staleConnection = try await fixture.act(
        "browser_click",
        [
          "target": .string(try final.reference("Download draft receipt"))
        ], observation: final)
      #expect(Fixture.field(staleConnection, "error") == .string("browser_observation_required"))
      let restarted = try await fixture.observe()
      #expect(restarted.text.contains("about:blank"))
      #expect(try fixture.submissionRequestCount() == 1)
      await fixture.cleanup()
    } catch {
      await fixture.cleanup()
      throw error
    }
  }

  @Test
  func slowSubmitProducesOneRecordedEffectAndAnUncertainReceiptWithoutReplay() async throws {
    let fixture = try Fixture()
    do {
      try await fixture.start()
      let blank = try await fixture.observe()
      let formURL = fixture.endpoint.appendingPathComponent("form").absoluteString + "?slow=1"
      _ = try await fixture.act("browser_navigate", ["url": .string(formURL)], observation: blank)
      let form = try await fixture.observe()
      _ = try await fixture.act(
        "browser_type",
        [
          "target": .string(try form.reference("Draft label")),
          "text": .string("Uncertain local draft"),
        ], observation: form)
      let filled = try await fixture.observe()
      let arguments: [String: JSONValue] = [
        "target": .string(try filled.reference("Save local draft"))
      ]
      let uncertain = try await fixture.act("browser_click", arguments, observation: filled)
      #expect(uncertain.status == .failure)
      #expect(uncertain.requiresUserAttention)
      #expect(Fixture.field(uncertain, "error") == .string("browser_action_outcome_uncertain"))
      #expect(try fixture.state()["submission_count"] == .integer(1))
      #expect(try fixture.submissionRequestCount() == 1)
      let staleReplay = try await fixture.act("browser_click", arguments, observation: filled)
      #expect(Fixture.field(staleReplay, "error") == .string("browser_observation_required"))
      #expect(try fixture.submissionRequestCount() == 1)
      await fixture.cleanup()
    } catch {
      await fixture.cleanup()
      throw error
    }
  }

  private struct Observation {
    let id: String
    let text: String

    func reference(_ label: String) throws -> String {
      guard let line = text.split(separator: "\n").first(where: { $0.contains("\"\(label)\"") }),
        let range = line.range(of: #"\[ref=(?:f\d+)?e\d+\]"#, options: .regularExpression)
      else { throw FixtureError.missingElement(label) }
      return String(line[range].dropFirst(5).dropLast())
    }
  }

  private enum FixtureError: Error {
    case missingToolsRoot
    case serverDidNotStart
    case browserUnavailable
    case missingObservation(String)
    case missingElement(String)
    case rerenderDidNotComplete
  }

  @MainActor
  private final class Fixture {
    let rootURL: URL
    let outputURL: URL
    private let process = Process()
    private let context = ToolExecutionContext(runID: AgentRunID())
    private var managed: MCPManagedToolExecutor?
    private var browser: HexGatewayBrowserToolExecutor?
    private var port = 0
    private let preservesEvidence: Bool
    private(set) var endpoint = URL(fileURLWithPath: "/")

    init() throws {
      let evidence = ProcessInfo.processInfo.environment[
        "HEX_BROWSER_QUALIFICATION_EVIDENCE_DIRECTORY"]
      preservesEvidence = evidence != nil
      let parent =
        evidence.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory
      rootURL = parent.appendingPathComponent(
        "hex-browser-workflow-\(UUID().uuidString)", isDirectory: true)
      outputURL = rootURL.appendingPathComponent("output", isDirectory: true)
      try FileManager.default.createDirectory(
        at: outputURL, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      var repository = URL(fileURLWithPath: #filePath)
      for _ in 0..<6 { repository.deleteLastPathComponent() }
      let program = repository.appendingPathComponent(
        "docs/qualification/observe-act-verify/browser_fixture.py")
      process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
      process.arguments = [program.path, "--state-directory", rootURL.path]
      process.environment = ["PATH": "/usr/bin:/bin", "PYTHONUNBUFFERED": "1"]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      do { try process.run() } catch {
        try? FileManager.default.removeItem(at: rootURL)
        throw error
      }
    }

    func start() async throws {
      let portFile = rootURL.appendingPathComponent("port.txt")
      let deadline = ContinuousClock.now.advanced(by: .seconds(5))
      while ContinuousClock.now < deadline {
        if let value = try? String(contentsOf: portFile, encoding: .utf8),
          let parsed = Int(value), (1...65_535).contains(parsed)
        {
          port = parsed
          break
        }
        try await Task.sleep(for: .milliseconds(20))
      }
      guard port > 0 else { throw FixtureError.serverDidNotStart }
      guard let loopbackURL = URL(string: "http://127.0.0.1:\(port)/") else {
        throw FixtureError.serverDidNotStart
      }
      endpoint = loopbackURL
      guard let toolsRoot = ProcessInfo.processInfo.environment["HEX_MANAGED_TOOLS_ROOT"] else {
        throw FixtureError.missingToolsRoot
      }
      let layout = try MCPManagedToolLayout(
        rootURL: URL(fileURLWithPath: toolsRoot, isDirectory: true))
      let normal = try MCPServerConfiguration.playwright(
        layout: layout, workspaceRoot: rootURL,
        sourceEnvironment: ["HOME": rootURL.path, "PATH": "/usr/bin:/bin"])
      var arguments = normal.arguments
      if let outputIndex = arguments.firstIndex(of: "--output-dir") {
        arguments[arguments.index(after: outputIndex)] = outputURL.path
      }
      arguments += ["--headless", "--timeout-action", "1500"]
      let configuration = try MCPServerConfiguration(
        serverID: normal.serverID,
        executableURL: normal.executableURL, arguments: arguments, workingDirectory: rootURL,
        environment: normal.environment, requestTimeoutMilliseconds: 15_000)
      let executor = try MCPManagedToolExecutor(
        session: LocalMCPClientSession(configuration: configuration))
      managed = executor
      browser = HexGatewayBrowserToolExecutor(base: executor) {
        await executor.connectionIdentity()
      }
      guard
        try await executor.availableTools().contains(where: {
          $0.name.hasSuffix("browser_snapshot")
        })
      else {
        throw FixtureError.browserUnavailable
      }
      print("Browser qualification fixture: \(rootURL.path)")
    }

    func observe() async throws -> Observation {
      let result = try await execute("browser_snapshot", [:])
      guard case .string(let id) = Self.field(result, "hex_observation_id") else {
        throw FixtureError.missingObservation(Self.text(result))
      }
      return Observation(id: id, text: Self.text(result))
    }

    func act(_ tool: String, _ arguments: [String: JSONValue], observation: Observation)
      async throws -> ToolResult
    {
      var arguments = arguments
      arguments["hex_observation_id"] = .string(observation.id)
      return try await execute(tool, arguments)
    }

    private func execute(_ tool: String, _ arguments: [String: JSONValue]) async throws
      -> ToolResult
    {
      guard let browser else { throw FixtureError.browserUnavailable }
      let call = ToolCall(name: "mcp_10_playwright_" + tool, arguments: arguments)
      _ = try await browser.authorizationRequest(for: call, in: context)
      let result = try await browser.execute(call, in: context)
      let path = rootURL.appendingPathComponent("browser-results.jsonl")
      var data = (try? Data(contentsOf: path)) ?? Data()
      data.append(try JSONEncoder().encode(result))
      data.append(0x0A)
      try data.write(to: path, options: .atomic)
      return result
    }

    func rerenderAndWait() async throws {
      var request = URLRequest(url: endpoint.appendingPathComponent("control/rerender"))
      request.httpMethod = "POST"
      _ = try await URLSession.shared.data(for: request)
      let deadline = ContinuousClock.now.advanced(by: .seconds(5))
      while ContinuousClock.now < deadline {
        if try state()["observed_generation"] == .integer(1) { return }
        try await Task.sleep(for: .milliseconds(20))
      }
      throw FixtureError.rerenderDidNotComplete
    }

    func state() throws -> [String: JSONValue] {
      try JSONDecoder().decode(
        [String: JSONValue].self,
        from: Data(contentsOf: rootURL.appendingPathComponent("state.json")))
    }

    func submissionRequestCount() throws -> Int {
      let data = try String(
        contentsOf: rootURL.appendingPathComponent("requests.jsonl"), encoding: .utf8)
      return try data.split(separator: "\n").filter { line in
        let value = try JSONDecoder().decode([String: JSONValue].self, from: Data(line.utf8))
        guard value["method"] == .string("POST"), case .string(let path) = value["path"] else {
          return false
        }
        return path.hasPrefix("/submit")
      }.count
    }

    func restartBrowser() async throws {
      guard let managed else { throw FixtureError.browserUnavailable }
      await managed.stop()
      let tools = try await managed.availableTools()
      guard !tools.isEmpty else { throw FixtureError.browserUnavailable }
    }

    func cleanup() async {
      await managed?.stop()
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
      if !preservesEvidence { try? FileManager.default.removeItem(at: rootURL) }
    }

    static func field(_ result: ToolResult, _ name: String) -> JSONValue? {
      guard case .object(let value) = result.output else { return nil }
      return value[name]
    }

    static func text(_ result: ToolResult) -> String {
      result.content.compactMap { item in
        guard case .text(let text) = item else { return nil }
        return text
      }.joined(separator: "\n")
    }
  }
}
