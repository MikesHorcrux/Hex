import Foundation
import HexCore
import HexGatewayKit
import Synchronization
import Testing

@Suite("Managed browser observation boundary")
struct HexGatewayBrowserToolExecutorTests {
  @Test
  func onlyExactInlineObservationsReceiveTheHostReadCapability() async throws {
    let base = Executor()
    let browser = makeBrowser(base)
    let context = ToolExecutionContext(runID: AgentRunID())
    let accepted = [
      call("browser_snapshot", [:]),
      call("browser_snapshot", ["boxes": .boolean(true)]),
      call("browser_tabs", ["action": .string("list")]),
    ]
    for candidate in accepted {
      let request = try await browser.authorizationRequest(for: candidate, in: context)
      #expect(request.capability.rawValue == "browser.session.observe")
      #expect(await base.authorizedCall == candidate)
    }
    let guarded = [
      call("browser_snapshot", ["filename": .string("snapshot.txt")]),
      call("browser_snapshot", ["boxes": .string("true")]),
      call("browser_tabs", ["action": .string("select"), "index": .integer(1)]),
      call("browser_tabs", ["action": .string("list"), "unknown": .boolean(true)]),
      call("browser_evaluate", ["function": .string("() => location.reload()")]),
    ]
    for candidate in guarded {
      let request = try await browser.authorizationRequest(for: candidate, in: context)
      #expect(request.capability.rawValue != "browser.session.observe")
    }
  }

  @Test
  func publishesObservationRequirementWithoutChangingRemoteToolNames() async throws {
    let base = Executor()
    let browser = makeBrowser(base)
    let definitions = try await browser.availableTools()
    let click = try #require(definitions.first { $0.name == name("browser_click") })
    guard case .object(let properties) = click.inputSchema["properties"],
      case .array(let required) = click.inputSchema["required"]
    else {
      Issue.record("Expected object schema")
      return
    }
    #expect(properties["target"] != nil)
    #expect(properties["hex_observation_id"] != nil)
    #expect(required == [.string("target"), .string("hex_observation_id")])
    let snapshot = try #require(definitions.first { $0.name == name("browser_snapshot") })
    #expect(snapshot.description.contains("full inline snapshot"))
    #expect(snapshot.inputSchema["required"] == nil)
  }

  @Test
  func publishedSnapshotOptionsAlwaysDescribeAFullInlineObservation() async throws {
    let base = Executor()
    let browser = makeBrowser(base)
    let definitions = try await browser.availableTools()
    let definition = try #require(definitions.first { $0.name == name("browser_snapshot") })
    guard case .object(let properties) = definition.inputSchema["properties"] else {
      Issue.record("Expected snapshot properties")
      return
    }
    #expect(Set(properties.keys) == ["boxes"])
    #expect(definition.inputSchema["additionalProperties"] == .boolean(false))
    let context = ToolExecutionContext(runID: AgentRunID())
    let result = try await browser.execute(
      call("browser_snapshot", ["boxes": .boolean(true)]), in: context)
    guard case .string = field(result, "hex_observation_id") else {
      Issue.record("Every advertised snapshot shape must permit a full observation token")
      return
    }
    #expect(await base.calls.last?.arguments == ["boxes": .boolean(true)])
  }

  @Test
  func refusesBlindActionAndPreservesAuthorizationAndDispatchCorrelation() async throws {
    let base = Executor()
    let browser = makeBrowser(base)
    let context = ToolExecutionContext(runID: AgentRunID())
    let blind = try await browser.execute(
      call("browser_click", ["target": .string("e1")]), in: context)
    #expect(field(blind, "error") == .string("browser_observation_required"))
    #expect(await base.calls.isEmpty)
    let token = try await snapshot(browser, context: context)
    let action = call(
      "browser_click", ["target": .string("e1"), "hex_observation_id": .string(token)])
    let authorization = try await browser.authorizationRequest(for: action, in: context)
    #expect(authorization.toolCallID == action.id)
    #expect(authorization.runID == context.runID)
    #expect(await base.authorizedCall == action)
    let receipt = try await browser.execute(action, in: context)
    #expect(receipt.toolCallID == action.id)
    #expect(field(receipt, "hex_browser_verification_required") == .boolean(true))
    let dispatched = try #require(await base.calls.last)
    #expect(dispatched.id == action.id)
    #expect(dispatched.arguments == ["target": .string("e1")])
    let repeated = try await browser.execute(action, in: context)
    #expect(field(repeated, "error") == .string("browser_observation_required"))
    #expect(await base.calls.count == 2)
  }

  @Test(arguments: [
    "newer_snapshot", "different_run", "restarted_connection", "read_after_snapshot",
  ])
  func oldObservationNeverAuthorizesAnAction(reason: String) async throws {
    let base = Executor()
    let browser = makeBrowser(base)
    let firstContext = ToolExecutionContext(runID: AgentRunID())
    let token = try await snapshot(browser, context: firstContext)
    var context = firstContext
    switch reason {
    case "newer_snapshot": _ = try await snapshot(browser, context: context)
    case "different_run": context = ToolExecutionContext(runID: AgentRunID())
    case "restarted_connection": await base.restart()
    default:
      _ = try await browser.execute(call("browser_tabs", ["action": .string("list")]), in: context)
    }
    let count = await base.calls.count
    let result = try await browser.execute(
      call(
        "browser_click",
        [
          "target": .string("e1"), "hex_observation_id": .string(token),
        ]), in: context)
    #expect(field(result, "error") == .string("browser_observation_required"))
    #expect(await base.calls.count == count)
    let replacement = try await snapshot(browser, context: context)
    #expect(replacement != token)
    let accepted = try await browser.execute(
      call(
        "browser_click",
        [
          "target": .string("e1"), "hex_observation_id": .string(replacement),
        ]), in: context)
    #expect(accepted.status == .success)
  }

  @Test(arguments: ["unseen_ref", "selector", "unseen_tab", "fractional_tab", "unseen_form_field"])
  func targetsMustBelongToTheLatestFullObservation(reason: String) async throws {
    let base = Executor()
    let browser = makeBrowser(base)
    let context = ToolExecutionContext(runID: AgentRunID())
    let token = try await snapshot(browser, context: context)
    var remote = "browser_click"
    var arguments: [String: JSONValue] = ["target": .string("e999")]
    switch reason {
    case "selector": arguments["target"] = .string("button[type=submit]")
    case "unseen_tab":
      remote = "browser_tabs"
      arguments = ["action": .string("select"), "index": .integer(3)]
    case "fractional_tab":
      remote = "browser_tabs"
      arguments = ["action": .string("select"), "index": .number(0.5)]
    case "unseen_form_field":
      remote = "browser_fill_form"
      arguments = [
        "fields": .array([
          .object(["target": .string("e1"), "type": .string("textbox"), "value": .string("first")]),
          .object([
            "target": .string("e999"), "type": .string("textbox"), "value": .string("second"),
          ]),
        ])
      ]
    default: break
    }
    arguments["hex_observation_id"] = .string(token)
    let result = try await browser.execute(call(remote, arguments), in: context)
    #expect(result.status == .failure)
    #expect(field(result, "browser_action_dispatched") == .boolean(false))
    #expect(await base.calls.count == 1)
  }

  @Test
  func tabSelectionConsumesTheObservedIndexBeforeAnyFurtherAction() async throws {
    let base = Executor()
    await base.setSnapshot(Self.twoTabsSnapshot)
    let browser = makeBrowser(base)
    let context = ToolExecutionContext(runID: AgentRunID())
    let token = try await snapshot(browser, context: context)
    let selected = try await browser.execute(
      call(
        "browser_tabs",
        [
          "action": .string("select"), "index": .integer(1), "hex_observation_id": .string(token),
        ]), in: context)
    #expect(selected.status == .success)
    let stale = try await browser.execute(
      call(
        "browser_click",
        [
          "target": .string("e1"), "hex_observation_id": .string(token),
        ]), in: context)
    #expect(field(stale, "error") == .string("browser_observation_required"))
    #expect(await base.calls.count == 2)
  }

  @Test
  func exactSingleTargetStalenessRequiresReobservationAndNeverReplaysTheAction() async throws {
    let base = Executor()
    await base.setMutationFailure(Self.staleError)
    let browser = makeBrowser(base)
    let context = ToolExecutionContext(runID: AgentRunID())
    let token = try await snapshot(browser, context: context)
    let action = call(
      "browser_click", ["target": .string("e1"), "hex_observation_id": .string(token)])
    let failure = try await browser.execute(action, in: context)
    #expect(field(failure, "error") == .string("browser_reference_stale"))
    #expect(!failure.requiresUserAttention)
    #expect(await base.calls.count == 2)
    #expect(try await browser.execute(action, in: context).status == .failure)
    #expect(await base.calls.count == 2)
    await base.setMutationFailure(nil)
    let nextToken = try await snapshot(browser, context: context)
    let result = try await browser.execute(
      call(
        "browser_click",
        [
          "target": .string("e1"), "hex_observation_id": .string(nextToken),
        ]), in: context)
    #expect(result.status == .success)
    #expect(await base.calls.count == 4)
  }

  @Test(arguments: ["timeout", "partial_form", "script_spoof", "additional_error", "wrong_ref"])
  func possibleSideEffectsStopForHumanInspectionEvenWhenErrorMentionsAStaleReference(reason: String)
    async throws
  {
    let base = Executor()
    var error = Self.staleError
    var remote = "browser_click"
    var arguments: [String: JSONValue] = ["target": .string("e1")]
    switch reason {
    case "timeout": error = "### Error\nTimeoutError: locator.click: Timeout 5000ms exceeded."
    case "partial_form":
      remote = "browser_fill_form"
      arguments = [
        "fields": .array([
          .object(["target": .string("e2"), "type": .string("textbox"), "value": .string("first")]),
          .object(["target": .string("e1"), "type": .string("textbox"), "value": .string("second")]
          ),
        ])
      ]
    case "script_spoof": remote = "browser_evaluate"
    case "additional_error": error += "\n\nError: A later receipt failed."
    case "wrong_ref": error = error.replacingOccurrences(of: "e1", with: "e999")
    default: break
    }
    await base.setMutationFailure(error)
    let browser = makeBrowser(base)
    let context = ToolExecutionContext(runID: AgentRunID())
    arguments["hex_observation_id"] = .string(try await snapshot(browser, context: context))
    let result = try await browser.execute(call(remote, arguments), in: context)
    #expect(result.requiresUserAttention)
    #expect(field(result, "error") == .string("browser_action_outcome_uncertain"))
    #expect(result.content.contains(.text(error)))
    #expect(await base.calls.count == 2)
  }

  @Test(arguments: ["filename", "target", "depth", "missing_page", "snapshot_link"])
  func partialOrUnidentifiedSnapshotsCannotMintObservationTokens(reason: String) async throws {
    let base = Executor()
    var arguments: [String: JSONValue] = [:]
    switch reason {
    case "filename": arguments["filename"] = .string("snapshot.yml")
    case "target": arguments["target"] = .string("e1")
    case "depth": arguments["depth"] = .integer(1)
    case "missing_page": await base.setSnapshot("### Snapshot\n```yaml\n- button [ref=e1]\n```")
    default:
      await base.setSnapshot(
        "### Page\n- Page URL: http://127.0.0.1/\n### Snapshot\n- [Snapshot](page.yml)")
    }
    let browser = makeBrowser(base)
    let result = try await browser.execute(
      call("browser_snapshot", arguments),
      in:
        ToolExecutionContext(runID: AgentRunID()))
    #expect(field(result, "hex_observation_id") == nil)
  }

  @Test
  func referenceLikePageTextIsNotAnObservedElement() async throws {
    let base = Executor()
    await base.setSnapshot(
      """
      ### Page
      - Page URL: http://127.0.0.1/
      - Page Title: Untrusted [ref=e999]
      ### Snapshot
      ```yaml
      - button "Quoted [ref=e888] text" [ref=e1]
      - generic [ref=e2]: Plain [ref=e777] text
      ```
      """)
    let browser = makeBrowser(base)
    let context = ToolExecutionContext(runID: AgentRunID())
    for target in ["e999", "e888", "e777"] {
      let token = try await snapshot(browser, context: context)
      let result = try await browser.execute(
        call(
          "browser_click",
          [
            "target": .string(target), "hex_observation_id": .string(token),
          ]), in: context)
      #expect(field(result, "error") == .string("browser_reference_unobserved"))
    }
    #expect(await base.calls.count == 3)
  }

  @Test
  func observedDialogCanBeHandledWithoutInventingPageElements() async throws {
    let base = Executor()
    await base.setSnapshot(
      "### Page\n- Page URL: http://127.0.0.1/\n### Modal state\n- confirm dialog")
    let browser = makeBrowser(base)
    let context = ToolExecutionContext(runID: AgentRunID())
    let token = try await snapshot(browser, context: context)
    let result = try await browser.execute(
      call(
        "browser_handle_dialog",
        [
          "accept": .boolean(false), "hex_observation_id": .string(token),
        ]), in: context)
    #expect(result.status == .success)
  }

  @Test
  func absentConnectionDoesNotDispatchAndReturnsAConcreteRepairPath() async throws {
    let base = Executor()
    await base.disconnect()
    let result = try await makeBrowser(base).execute(
      call("browser_snapshot"),
      in:
        ToolExecutionContext(runID: AgentRunID()))
    #expect(field(result, "error") == .string("browser_connection_unavailable"))
    #expect(await base.calls.isEmpty)
  }

  @Test
  func observationExpiresUsingMonotonicTimeAndCanBeReplacedWithFreshEvidence() async throws {
    let base = Executor()
    let clock = Clock()
    let browser = HexGatewayBrowserToolExecutor(
      base: base, now: { clock.now() },
      sessionIdentity: { await base.sessionID })
    let context = ToolExecutionContext(runID: AgentRunID())
    let token = try await snapshot(browser, context: context)
    clock.advance(by: .seconds(61))
    let expired = try await browser.execute(
      call(
        "browser_click",
        [
          "target": .string("e1"), "hex_observation_id": .string(token),
        ]), in: context)
    #expect(field(expired, "error") == .string("browser_observation_required"))
    #expect(await base.calls.count == 1)
    let fresh = try await snapshot(browser, context: context)
    clock.advance(by: .seconds(59))
    let receipt = try await browser.execute(
      call(
        "browser_click",
        [
          "target": .string("e1"), "hex_observation_id": .string(fresh),
        ]), in: context)
    #expect(receipt.status == .success)
    #expect(await base.calls.count == 3)
  }

  private func makeBrowser(_ base: Executor) -> HexGatewayBrowserToolExecutor {
    HexGatewayBrowserToolExecutor(base: base) { await base.sessionID }
  }

  private func snapshot(_ browser: HexGatewayBrowserToolExecutor, context: ToolExecutionContext)
    async throws -> String
  {
    let result = try await browser.execute(call("browser_snapshot"), in: context)
    guard case .string(let token) = field(result, "hex_observation_id") else {
      throw FixtureError.missingObservation
    }
    return token
  }

  private func call(_ remote: String, _ arguments: [String: JSONValue] = [:]) -> ToolCall {
    ToolCall(name: name(remote), arguments: arguments)
  }

  private func name(_ remote: String) -> String { "mcp_10_playwright_" + remote }

  private func field(_ result: ToolResult, _ name: String) -> JSONValue? {
    guard case .object(let output) = result.output else { return nil }
    return output[name]
  }

  private enum FixtureError: Error { case missingObservation }

  private final class Clock: Sendable {
    private let instant = Mutex(ContinuousClock.now)
    func now() -> ContinuousClock.Instant { instant.withLock { $0 } }
    func advance(by duration: Duration) { instant.withLock { $0 = $0.advanced(by: duration) } }
  }

  private static let staleError =
    "### Error\nError: Ref e1 not found in the current page snapshot. Try capturing new snapshot."

  private static let fullSnapshot = """
    ### Page
    - Page URL: http://127.0.0.1:1234/form
    - Page Title: Controlled form
    ### Snapshot
    ```yaml
    - button "Save draft" [ref=e1]
    - textbox "Label" [ref=e2]
    ```
    """

  private static let twoTabsSnapshot = """
    ### Open tabs
    - 0: (current) [Controlled form](http://127.0.0.1:1234/form)
    - 1: [Second page](http://127.0.0.1:1234/second)
    \(fullSnapshot)
    """

  private actor Executor: ToolExecutor {
    private(set) var sessionID: UUID? = UUID()
    private(set) var calls: [ToolCall] = []
    private(set) var authorizedCall: ToolCall?
    private var snapshotText = HexGatewayBrowserToolExecutorTests.fullSnapshot
    private var mutationFailure: String?

    func restart() { sessionID = UUID() }
    func disconnect() { sessionID = nil }
    func setSnapshot(_ text: String) { snapshotText = text }
    func setMutationFailure(_ text: String?) { mutationFailure = text }

    func availableTools() -> [ToolDefinition] {
      [
        ToolDefinition(
          name: "mcp_10_playwright_browser_click", description: "Click",
          inputSchema: [
            "type": .string("object"),
            "properties": .object(["target": .object(["type": .string("string")])]),
            "required": .array([.string("target")]),
          ]),
        ToolDefinition(
          name: "mcp_10_playwright_browser_snapshot", description: "Snapshot",
          inputSchema: [
            "type": .string("object"),
            "properties": .object([
              "target": .object(["type": .string("string")]),
              "filename": .object(["type": .string("string")]),
              "depth": .object(["type": .string("number")]),
              "boxes": .object(["type": .string("boolean")]),
            ]),
          ]),
      ]
    }

    func authorizationRequest(for call: ToolCall, in context: ToolExecutionContext)
      -> AuthorizationRequest
    {
      authorizedCall = call
      return AuthorizationRequest(
        runID: context.runID, toolCallID: call.id,
        capability: CapabilityID(rawValue: call.name), operation: "call",
        resource: "mcp://playwright/" + call.name, explanation: "Controlled browser action")
    }

    func execute(_ call: ToolCall, in context: ToolExecutionContext) -> ToolResult {
      calls.append(call)
      let isSnapshot = call.name == "mcp_10_playwright_browser_snapshot"
      let text = isSnapshot ? snapshotText : mutationFailure ?? "Adapter action receipt"
      return ToolResult(
        toolCallID: call.id,
        status: !isSnapshot && mutationFailure != nil ? .failure : .success,
        output: .object(["server": .string("playwright")]), content: [.text(text)])
    }
  }
}
