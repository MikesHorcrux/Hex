import Foundation
import HexCapabilities
import HexCore
import Testing

@Suite("Personal agent tool executor")
struct PersonalAgentToolExecutorTests {
  @Test
  func publishesCodingMacAndWebToolsThroughOneRuntimeBoundary() async throws {
    let workspaceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: workspaceURL,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: workspaceURL) }

    let applicationController = ApplicationController()
    let executor = try PersonalAgentToolExecutor(
      fileSystem: WorkspaceFileSystem(root: workspaceURL),
      processExecutor: ProcessExecutor(),
      applicationController: applicationController,
      accessibilityController: AccessibilityController(),
      addressValidator: AddressValidator(),
      webFetcher: Fetcher()
    )

    let names = try await executor.availableTools().map(\.name)

    #expect(names == names.sorted())
    #expect(names.count == 13)
    #expect(names.contains("process_run"))
    #expect(names.contains("workspace_write_text_file"))
    #expect(names.contains("mac_accessibility_action"))
    #expect(names.contains("mac_list_applications"))
    #expect(names.contains("web_fetch"))
    #expect(names.contains("web_search"))
  }

  private actor ProcessExecutor: ProcessExecuting {
    func execute(_ request: ProcessExecutionRequest) async throws -> ProcessExecutionResult {
      ProcessExecutionResult(
        termination: .exited(code: 0),
        output: Data(),
        durationMilliseconds: 0
      )
    }
  }

  private actor ApplicationController: MacApplicationControlling {
    func runningApplications() async throws -> [MacApplicationSnapshot] { [] }

    func activateApplication(
      bundleIdentifier: String
    ) async throws -> MacApplicationActivationResult {
      MacApplicationActivationResult(bundleIdentifier: bundleIdentifier, wasRunning: true)
    }

    func openURL(_ url: URL) async throws {}
  }

  private actor AccessibilityController: MacAccessibilityControlling {
    func isTrusted(promptIfNeeded: Bool) async -> Bool { true }

    func snapshot(
      bundleIdentifier: String,
      maximumDepth: Int,
      maximumElements: Int
    ) async throws -> MacAccessibilitySnapshot {
      MacAccessibilitySnapshot(
        bundleIdentifier: bundleIdentifier,
        applicationName: bundleIdentifier,
        processIdentifier: 1,
        elements: [],
        isTruncated: false
      )
    }

    func perform(
      _ request: MacAccessibilityActionRequest
    ) async throws -> MacAccessibilityActionResult {
      MacAccessibilityActionResult(
        bundleIdentifier: request.bundleIdentifier,
        path: request.selector.path ?? "0",
        action: request.action
      )
    }
  }

  private actor AddressValidator: WebAddressValidating {
    func validate(_ url: URL) async throws {}
  }

  private actor Fetcher: WebFetching {
    func fetch(_ request: WebFetchRequest) async throws -> WebFetchResponse {
      WebFetchResponse(
        url: request.url,
        statusCode: 200,
        contentType: "text/plain",
        body: Data(),
        isTruncated: false
      )
    }
  }
}
