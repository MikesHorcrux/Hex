import AppKit
import Foundation
import HexCore
import HexGatewayKit
import HexIPC
import HexMCP
import HexPersistence
import SwiftUI
import Testing
import Vision

@testable import Hex

/// Explicitly opted in: real SwiftUI controls and local protocol fixtures, no resident or live secrets.
@Suite("Hosted MCP setup qualification", .timeLimit(.minutes(2)))
struct HexMCPSetupViewCaptureTests {
  @Test @MainActor
  func saveCheckAndCaptureControlledServers() async throws {
    guard let requestedPath = ProcessInfo.processInfo.environment["HEX_MCP_SETUP_CAPTURE_DIRECTORY"]
    else { return }
    let output = URL(fileURLWithPath: requestedPath).resolvingSymlinksInPath().standardizedFileURL
    let temporaryRoots = [FileManager.default.temporaryDirectory, URL(fileURLWithPath: "/tmp")]
      .map { $0.resolvingSymlinksInPath().standardizedFileURL.path + "/" }
    #expect(temporaryRoots.contains { output.path.hasPrefix($0) })
    guard temporaryRoots.contains(where: { output.path.hasPrefix($0) }) else {
      throw FixtureError.nonTemporaryOutput
    }
    try FileManager.default.createDirectory(
      at: output, withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])

    let fixture = try HexControlledMCPServerFixture()
    defer { fixture.cleanup() }
    let endpoint = try await fixture.start()
    let paths = try HexResidentDataPaths(
      settingsURL: fixture.root.appendingPathComponent("resident.json"),
      databaseURL: fixture.root.appendingPathComponent("journal.sqlite"),
      heartbeatStoreURL: fixture.root.appendingPathComponent("heartbeats.json"))
    let store = try JSONHexResidentRuntimeSettingsStore(fileURL: paths.settingsURL)
    try await store.save(
      HexResidentRuntimeSettings(
        modelID: "fixture-model", workspaceRoot: fixture.root))
    let usesKeychain = ProcessInfo.processInfo.environment["HEX_MCP_SETUP_USE_KEYCHAIN"] == "1"
    let secrets: any HexSecretStore =
      usesKeychain
      ? KeychainHexSecretStore(
        service: "com.lunarmothstudios.Hex.mcp-fixture.\(UUID().uuidString)", account: "fixture")
      : SecretStore()
    let service = FixtureService()
    let reloader = FixtureReloader(paths: paths, store: store, secrets: secrets, service: service)
    let model = HexResidentSetupModel(
      settingsStore: store, secretStore: secrets, configurationReloader: reloader)
    await model.load()
    #expect(
      model.addHTTPMCPServer(
        serverID: "remote", endpoint: endpoint.absoluteString,
        bearerToken: HexControlledMCPServerFixture.token))
    let stdio = try HexControlledMCPServerFixture.stdioConfiguration()
    let stdioScript = fixture.root.appendingPathComponent("stdio.awk")
    try HexControlledMCPServerFixture.stdioProgram.write(
      to: stdioScript, atomically: true, encoding: .utf8)
    #expect(
      model.addStdioMCPServer(
        serverID: "local", executablePath: stdio.executableURL.path,
        argumentsText: "-f\n\(stdioScript.path)", workingDirectoryPath: fixture.root.path))
    let workspace = AgentWorkspaceModel(client: PreviewHexAgentClient())
    await workspace.connect()
    let connections = HexToolConnectionsModel(service: service)
    connections.connectionChanged(.connected)
    await connections.refresh()
    let rootView = HexToolsSettingsView(
      model: model, connections: connections, workspace: workspace, suppressAutomaticRefresh: true
    )
    .background(Color(nsColor: .windowBackgroundColor))
    .environment(\.colorScheme, .light)
    let hosting = NSHostingView(rootView: rootView)
    let window = NSWindow(
      contentRect: NSRect(x: 80, y: 80, width: 1_000, height: 1_900),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Hex MCP qualification — synthetic local servers"
    window.appearance = NSAppearance(named: .aqua)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.orderFront(nil)
    defer { window.close() }
    try await settle(hosting)
    try capture(hosting, to: output.appendingPathComponent("01-ready-to-save.png"))

    do {
      if usesKeychain {
        try await secrets.save("fixture-provider-not-used", for: .openAIAPIKey)
      }
      try press("Save", in: hosting)
      try await waitUntil {
        model.saveGeneration == 1 || (!model.isSaving && model.errorMessage != nil)
      }
      #expect(model.saveGeneration == 1)
      #expect(model.errorMessage == nil)
      let savedText = try String(contentsOf: paths.settingsURL, encoding: .utf8)
      #expect(!savedText.contains(HexControlledMCPServerFixture.token))
      #expect(model.httpMCPServers.first?.hasStoredBearerToken == true)
      try press("Refresh status", in: hosting)
      try await waitUntil { connections.servers.count == 2 }
      try await settle(hosting)
      try capture(hosting, to: output.appendingPathComponent("02-saved.png"))

      try press("Check connection: remote", in: hosting)
      try await waitUntil {
        connections.servers.contains { $0.serverID == "remote" && $0.state == .ready }
      }
      try press("Check connection: local", in: hosting)
      try await waitUntil { connections.servers.allSatisfy { $0.state == .ready } }
      let remote = try await service.call(serverID: "remote")
      let local = try await service.call(serverID: "local")
      #expect(remote.content.contains(.text("http receipt hosted-ui")))
      #expect(local.content.contains(.text("stdio receipt")))
      try await settle(hosting)
      try capture(hosting, to: output.appendingPathComponent("03-connected.png"))

      try fixture.update(mode: "revoked")
      try press("Check connection: remote", in: hosting)
      try await waitUntil {
        connections.servers.contains {
          $0.serverID == "remote" && $0.failure == .authenticationRejected
        }
      }
      try await settle(hosting)
      try capture(hosting, to: output.appendingPathComponent("04-revoked.png"))
      try fixture.update()
      try press("Retry connection: remote", in: hosting)
      try await waitUntil {
        connections.servers.contains { $0.serverID == "remote" && $0.state == .ready }
      }
      let proof: [String: String] = [
        "setup":
          "real HexToolsSettingsView with temporary persisted settings and synthetic secrets",
        "controls":
          "Save, Refresh status, Check connection and Retry connection pressed through rendered controls",
        "http": "authenticated loopback tools discovered; harmless HTTP receipt received",
        "stdio": "local process tools discovered; harmless stdio receipt received",
        "recovery": "revoked HTTP authorization displayed; explicit retry recovered",
        "credentialStorage": usesKeychain
          ? "signed Keychain storage in a unique fixture service; synthetic keys deleted and absence verified"
          : "in-memory synthetic secret store",
        "limitations": "no resident XPC, production credentials or cloud inference used",
      ]
      let hold = min(
        60,
        max(0, Int(ProcessInfo.processInfo.environment["HEX_MCP_SETUP_HOLD_SECONDS"] ?? "0") ?? 0))
      if hold > 0 { try await Task.sleep(for: .seconds(hold)) }
      await service.stop()
      if usesKeychain { try await removeFixtureCredentials(in: secrets, endpoint: endpoint) }
      try JSONEncoder().encode(proof).write(to: output.appendingPathComponent("qualification.json"))
    } catch {
      await service.stop()
      if usesKeychain {
        do {
          try await removeFixtureCredentials(in: secrets, endpoint: endpoint)
        } catch {
          Issue.record("Synthetic fixture Keychain cleanup could not be verified.")
        }
      }
      throw error
    }
  }

  private func removeFixtureCredentials(in store: any HexSecretStore, endpoint: URL) async throws {
    let mcpKey = try HexSecretKey.mcpBearerToken(serverID: "remote", endpointURL: endpoint)
    for key in [HexSecretKey.openAIAPIKey, mcpKey] {
      try await store.delete(key)
      let exists = try await store.exists(key)
      try #require(
        !exists, "Only fixture credentials were created, and they must be absent after cleanup.")
    }
  }

  @MainActor
  private func settle(_ view: NSView) async throws {
    view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(200))
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
  }

  @MainActor
  private func capture(_ view: NSView, to url: URL) throws {
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    try data.write(to: url)
  }

  @MainActor
  private func press(_ label: String, in view: NSView) throws {
    let candidates = accessibilityElements(view)
    if let element = candidates.first(where: {
      ($0.accessibilityLabel() == label || $0.accessibilityTitle() == label)
        && $0.accessibilityRole() == .button
    }) {
      try #require(element.accessibilityPerformPress())
      return
    }

    // SwiftUI may not vend AX nodes in a hosted test without an external AX client. Locate the
    // real rendered label in this view's bitmap, then dispatch native window mouse events.
    // This never reads the screen, uses global input, requests TCC access, or invokes a model action.
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let image = try #require(bitmap.cgImage)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    let lines = (request.results ?? []).compactMap { observation -> (text: String, rect: CGRect)? in
      guard let text = observation.topCandidates(1).first?.string else { return nil }
      return (text, observation.boundingBox)
    }
    let parts = label.components(separatedBy: ": ")
    let title = parts[0]
    var buttons = lines.filter { $0.text == title }
    if parts.count == 2 {
      let anchors = lines.filter { $0.text == parts[1] }
      buttons.sort { first, second in
        let firstDistance = anchors.map { abs($0.rect.midY - first.rect.midY) }.min() ?? 1
        let secondDistance = anchors.map { abs($0.rect.midY - second.rect.midY) }.min() ?? 1
        return firstDistance < secondDistance
      }
      try #require(!anchors.isEmpty, "Expected the rendered server row \(parts[1]).")
    }
    let button = try #require(
      buttons.first,
      "Expected rendered \(label); OCR text: \(lines.map(\.text).joined(separator: "; "))")
    let point = NSPoint(
      x: button.rect.midX * view.bounds.width,
      y: (view.isFlipped ? 1 - button.rect.midY : button.rect.midY) * view.bounds.height)
    let window = try #require(view.window)
    let location = view.convert(point, to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let event = try #require(
        NSEvent.mouseEvent(
          with: type, location: location, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
          pressure: 1))
      window.sendEvent(event)
    }
  }

  @MainActor
  private func accessibilityElements(_ root: NSView) -> [any NSAccessibilityProtocol] {
    var pending: [Any] = [root]
    var visited: Set<ObjectIdentifier> = []
    var result: [any NSAccessibilityProtocol] = []
    while let next = pending.popLast(), visited.count < 2_048 {
      guard let object = next as? NSObject,
        visited.insert(ObjectIdentifier(object)).inserted
      else { continue }
      if let element = object as? any NSAccessibilityProtocol {
        result.append(element)
        pending.append(contentsOf: element.accessibilityChildren() ?? [])
      }
      if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
    }
    return result
  }

  @MainActor
  private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<600 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw FixtureError.timedOut
  }

  private enum FixtureError: Error {
    case nonTemporaryOutput, timedOut, missingSecret, notConfigured
  }

  private actor SecretStore: HexSecretStore {
    private var values: [HexSecretKey: String] = [:]
    func exists(_ key: HexSecretKey) -> Bool { key == .openAIAPIKey || values[key] != nil }
    func secret(for key: HexSecretKey) throws -> String {
      guard let value = values[key] else { throw FixtureError.missingSecret }
      return value
    }
    func save(_ secret: String, for key: HexSecretKey) { values[key] = secret }
    func delete(_ key: HexSecretKey) { values[key] = nil }
  }

  private actor InferenceStore: HexInferenceBackendSettingsStore {
    func load() throws -> HexInferenceBackendSettings? {
      try HexInferenceBackendSettings(openAIModelID: "fixture-model")
    }
    func save(_ settings: HexInferenceBackendSettings) {}
  }

  @MainActor
  private final class FixtureReloader: HexResidentConfigurationReloading {
    let paths: HexResidentDataPaths
    let store: any HexResidentRuntimeSettingsStore
    let secrets: any HexSecretStore
    let service: FixtureService

    init(
      paths: HexResidentDataPaths, store: any HexResidentRuntimeSettingsStore,
      secrets: any HexSecretStore, service: FixtureService
    ) {
      self.paths = paths
      self.store = store
      self.secrets = secrets
      self.service = service
    }

    func reloadAfterConfigurationChange() async throws {
      let configuration = try await HexGatewayResidentConfiguration.loadPersisted(
        paths: paths, settingsStore: store, secretStore: secrets,
        inferenceBackendSettingsStore: InferenceStore())
      try await service.configure(configuration)
    }
  }

  private actor FixtureService: HexToolServerHealthServicing {
    private var executors: [MCPManagedToolExecutor] = []
    private var controller: HexGatewayToolServerController?

    func configure(_ configuration: HexGatewayResidentConfiguration) async throws {
      await stop()
      executors = try configuration.mcpClientSessions.map {
        try MCPManagedToolExecutor(session: $0, waitsForInitialDiscovery: false)
      }
      controller = try HexGatewayToolServerController(
        executors: executors, settings: configuration.mcpServerSettings)
    }

    func toolServerHealth() async throws -> GatewayToolServerHealth {
      try await controller?.health() ?? GatewayToolServerHealth()
    }

    func refreshToolServer(_ request: GatewayToolServerRequest) async throws
      -> GatewayToolServerStatus
    {
      guard let controller else { throw FixtureError.notConfigured }
      return try await controller.refresh(request)
    }

    func call(serverID: String) async throws -> ToolResult {
      let executor = try #require(executors.first { $0.serverID == serverID })
      let tools = try await executor.availableTools()
      let tool = try #require(tools.first)
      return try await executor.execute(
        ToolCall(name: tool.name, arguments: ["operation": .string("hosted-ui")]),
        in: ToolExecutionContext(runID: AgentRunID()))
    }

    func stop() async {
      for executor in executors { await executor.stop() }
      executors = []
      controller = nil
    }
  }
}
