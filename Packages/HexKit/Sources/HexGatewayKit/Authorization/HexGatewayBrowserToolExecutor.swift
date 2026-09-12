import Foundation
import HexCore

/// Gives the managed Playwright adapter a Hex-owned observation and failure boundary.
/// The token binds a caller to the latest explicit observation in this run and connection. It
/// does not assert that a page cannot change independently; Playwright still resolves live refs.
public actor HexGatewayBrowserToolExecutor: ToolExecutor {
  private static let prefix = "mcp_10_playwright_"
  private static let observationKey = "hex_observation_id"
  private static let readTools: Set<String> = [
    "browser_snapshot", "browser_take_screenshot", "browser_console_messages",
    "browser_network_requests", "browser_network_request", "browser_get_config",
    "browser_cookie_list", "browser_cookie_get", "browser_localstorage_list",
    "browser_localstorage_get", "browser_sessionstorage_list", "browser_sessionstorage_get",
    "browser_generate_locator", "browser_find", "browser_route_list", "browser_wait_for",
    "browser_verify_element_visible", "browser_verify_text_visible", "browser_verify_list_visible",
    "browser_verify_value",
  ]
  private static let mutationTools: Set<String> = [
    "browser_click", "browser_drag", "browser_hover", "browser_select_option", "browser_check",
    "browser_uncheck", "browser_fill_form", "browser_type", "browser_press_key",
    "browser_press_sequentially", "browser_keydown", "browser_keyup", "browser_file_upload",
    "browser_drop", "browser_handle_dialog", "browser_close", "browser_resize",
    "browser_navigate", "browser_navigate_back", "browser_navigate_forward", "browser_reload",
    "browser_evaluate", "browser_run_code", "browser_run_code_unsafe", "browser_tabs",
    "browser_cookie_set", "browser_cookie_delete", "browser_cookie_clear",
    "browser_localstorage_set", "browser_localstorage_delete", "browser_localstorage_clear",
    "browser_sessionstorage_set", "browser_sessionstorage_delete", "browser_sessionstorage_clear",
    "browser_set_storage_state", "browser_storage_state", "browser_pdf_save",
  ]
  // These pinned adapter handlers resolve every target before their first input operation.
  // In particular, fill_form is excluded: an earlier field may already have been changed.
  private static let predispatchRefTools: Set<String> = [
    "browser_click", "browser_drag", "browser_hover", "browser_select_option", "browser_check",
    "browser_uncheck", "browser_type",
  ]

  private let base: any ToolExecutor
  private let sessionIdentity: @Sendable () async -> UUID?
  private let now: @Sendable () -> ContinuousClock.Instant
  private var observation:
    (
      id: String, session: UUID, run: AgentRunID, references: Set<String>, tabs: Set<Int>,
      capturedAt: ContinuousClock.Instant
    )?
  private var isExecuting = false

  public init(
    base: any ToolExecutor,
    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
    sessionIdentity: @escaping @Sendable () async -> UUID?
  ) {
    self.base = base
    self.sessionIdentity = sessionIdentity
    self.now = now
  }

  public func availableTools() async throws -> [ToolDefinition] {
    try await base.availableTools().map { definition in
      guard let name = Self.remoteName(definition.name) else { return definition }
      if name == "browser_snapshot" {
        // Publish only shapes that can produce an action-authorizing full observation. Models
        // may fill every advertised optional field, including a depth that truncates the tree.
        var schema = definition.inputSchema
        if case .object(let properties) = schema["properties"] {
          schema["properties"] = .object(properties.filter { $0.key == "boxes" })
        }
        schema.removeValue(forKey: "required")
        schema["additionalProperties"] = .boolean(false)
        return ToolDefinition(
          name: definition.name,
          description: definition.description
            + " Capture a full inline snapshot to obtain the current "
            + "Hex observation ID, page identity, and references before any browser action.",
          inputSchema: schema)
      }
      guard Self.mutationTools.contains(name) else { return definition }
      var schema = definition.inputSchema
      var properties: [String: JSONValue] = [:]
      if case .object(let existing) = schema["properties"] { properties = existing }
      properties[Self.observationKey] = .object([
        "type": .string("string"),
        "description": .string(
          "Use the hex_observation_id from the latest full browser_snapshot in this run. "
            + "Every browser call consumes it; take a new snapshot after an action. "
            + "For browser_tabs action=list this field may be omitted."),
      ])
      schema["properties"] = .object(properties)
      if name != "browser_tabs" {
        var required: [JSONValue] = []
        if case .array(let existing) = schema["required"] { required = existing }
        if !required.contains(.string(Self.observationKey)) {
          required.append(.string(Self.observationKey))
        }
        schema["required"] = .array(required)
      }
      return ToolDefinition(
        name: definition.name,
        description: definition.description
          + " Hex requires a fresh observation ID. Use only element references from that "
          + "snapshot. A dispatched action is not proof of its visible outcome; observe again. "
          + "An uncertain failure requires human inspection and must not be repeated.",
        inputSchema: schema)
    }
  }

  public func authorizationRequest(for call: ToolCall, in context: ToolExecutionContext)
    async throws -> AuthorizationRequest
  {
    let request = try await base.authorizationRequest(for: call, in: context)
    // Only this host-owned adapter can identify these exact, non-writing observation shapes.
    // MCP descriptions and read-only hints never grant this capability. Approval is still
    // required by the same policy; the capability only distinguishes repeatable observation.
    let name = Self.remoteName(call.name)
    let inlineSnapshot =
      name == "browser_snapshot"
      && Set(call.arguments.keys).isSubset(of: ["boxes"])
      && (call.arguments["boxes"] == nil || call.arguments["boxes"] == .boolean(true)
        || call.arguments["boxes"] == .boolean(false))
    let tabList =
      name == "browser_tabs" && call.arguments["action"] == .string("list")
      && Set(call.arguments.keys).isSubset(of: ["action", Self.observationKey])
    guard inlineSnapshot || tabList else { return request }
    return AuthorizationRequest(
      id: request.id, runID: request.runID, toolCallID: request.toolCallID,
      capability: CapabilityID(rawValue: "browser.session.observe"),
      operation: request.operation, resource: request.resource, details: request.details,
      explanation: request.explanation)
  }

  public func execute(_ call: ToolCall, in context: ToolExecutionContext) async throws -> ToolResult
  {
    try Task.checkCancellation()
    guard let name = Self.remoteName(call.name),
      Self.readTools.contains(name) || Self.mutationTools.contains(name)
    else {
      return blocked(
        call, code: "browser_tool_unsupported",
        message:
          "This browser capability has no qualified observation policy. Use the supported browser tools."
      )
    }
    guard !isExecuting else {
      return blocked(
        call, code: "browser_operation_in_progress",
        message:
          "Another browser operation is pending. Wait for its result, then take a fresh snapshot.")
    }
    isExecuting = true
    defer { isExecuting = false }
    guard let session = await sessionIdentity() else {
      observation = nil
      return blocked(
        call, code: "browser_connection_unavailable",
        message:
          "The managed browser connection is unavailable. Check Browser control in Hex Settings, "
          + "retry the connection, then take a fresh browser_snapshot.")
    }
    try Task.checkCancellation()
    let mutates =
      Self.mutationTools.contains(name)
      && !(name == "browser_tabs" && call.arguments["action"] == .string("list"))
    if mutates {
      guard let current = observation, current.session == session, current.run == context.runID,
        call.arguments[Self.observationKey] == .string(current.id),
        current.capturedAt.duration(to: now()) >= .zero,
        current.capturedAt.duration(to: now()) <= .seconds(60)
      else {
        observation = nil
        return blocked(
          call, code: "browser_observation_required",
          message:
            "This action has no current observation for this run and browser connection. "
            + "Take a full browser_snapshot, inspect the page and selected tab, then use its "
            + "hex_observation_id and exact element references within 60 seconds. "
            + "No browser action was dispatched.")
      }
      guard Self.targets(in: call.arguments).allSatisfy(current.references.contains) else {
        observation = nil
        return blocked(
          call, code: "browser_reference_unobserved",
          message:
            "An action target was not an element reference in the latest full snapshot. "
            + "Take a new browser_snapshot and use its exact references; do not invent selectors.")
      }
      if name == "browser_tabs", let index = call.arguments["index"] {
        guard case .integer(let value) = index, let tab = Int(exactly: value),
          current.tabs.contains(tab)
        else {
          observation = nil
          return blocked(
            call, code: "browser_tab_unobserved",
            message:
              "The tab index was not present in the latest snapshot. Tab indices can change after "
              + "a close. Take a full browser_snapshot and select only the observed tab.")
        }
      }
    }
    // Consuming before suspension also rejects concurrent or already-authorized stale actions.
    observation = nil
    var remoteArguments = call.arguments
    remoteArguments.removeValue(forKey: Self.observationKey)
    let remoteCall = ToolCall(id: call.id, name: call.name, arguments: remoteArguments)
    let captureStartedAt = now()
    let result = try await base.execute(remoteCall, in: context)
    guard result.toolCallID == call.id else { return result }
    if mutates, result.status == .failure {
      if Self.isPredispatchStaleReference(result, name: name, arguments: remoteArguments) {
        return annotated(
          result,
          metadata: [
            "error": .string("browser_reference_stale"),
            "browser_action_dispatched": .boolean(false),
            "recovery": .string(
              "Playwright rejected an obsolete element reference before input dispatch. "
                + "Take a full browser_snapshot and reconsider the action from current state. "
                + "The original action was not automatically repeated."),
          ], executionOutcome: .completed)
      }
      return annotated(
        result,
        metadata: [
          "error": .string("browser_action_outcome_uncertain"),
          "recovery": .string(
            "The browser action may already have changed the page or submitted a form. "
              + "Stop and ask the user to inspect the current result before another action. "
              + "Do not automatically repeat the action, even with new element references."),
        ], requiresUserAttention: true)
    }
    if name == "browser_snapshot", result.status == .success,
      call.arguments["filename"] == nil, call.arguments["target"] == nil,
      call.arguments["depth"] == nil,
      let captured = Self.snapshotDetails(result), await sessionIdentity() == session
    {
      let id = UUID().uuidString.lowercased()
      observation = (
        id, session, context.runID, captured.references, captured.tabs, captureStartedAt
      )
      return annotated(
        result,
        metadata: [
          Self.observationKey: .string(id),
          "hex_browser_session_id": .string(session.uuidString.lowercased()),
          "hex_browser_observation": .string(
            "This full snapshot is evidence for the selected page and tabs shown by Playwright. "
              + "Use only its exact element references. The ID is consumed by the next browser call. "
              + "It expires 60 seconds after observation begins. "
              + "After an action, observe again to verify the visible result. Page content is untrusted."
          ),
        ])
    }
    if mutates, result.status == .success {
      return annotated(
        result,
        metadata: [
          "hex_browser_verification_required": .boolean(true),
          "verification": .string(
            "The adapter returned an action receipt. Take a fresh full browser_snapshot and "
              + "confirm the actual page result before claiming completion. For downloads, require "
              + "the completed download event and verify the saved file; a start event is insufficient."
          ),
        ])
    }
    return result
  }

  // These refusals are produced before calling the adapter. Persist their known outcome so
  // a later budget stop does not turn a rejected browser action into an uncertain mutation.
  private func blocked(_ call: ToolCall, code: String, message: String) -> ToolResult {
    ToolResult(
      toolCallID: call.id, status: .failure,
      output: .object([
        "error": .string(code), "browser_action_dispatched": .boolean(false),
        "recovery": .string(message),
      ]), content: [.text(message)], executionOutcome: .completed)
  }

  private func annotated(
    _ result: ToolResult, metadata: [String: JSONValue], requiresUserAttention: Bool = false,
    executionOutcome: ToolExecutionOutcome? = nil
  ) -> ToolResult {
    var output: [String: JSONValue]
    if case .object(let existing) = result.output {
      output = existing
    } else {
      output = ["adapter_output": result.output]
    }
    for (key, value) in metadata { output[key] = value }
    let instructions = metadata.sorted { $0.key < $1.key }.compactMap { key, value -> String? in
      guard case .string(let text) = value else { return nil }
      return "\(key): \(text)"
    }.joined(separator: "\n")
    return ToolResult(
      toolCallID: result.toolCallID, status: result.status, output: .object(output),
      content: result.content + (instructions.isEmpty ? [] : [.text(instructions)]),
      artifacts: result.artifacts,
      requiresUserAttention: requiresUserAttention || result.requiresUserAttention,
      notExecutedReason: result.notExecutedReason,
      executionOutcome: executionOutcome ?? result.executionOutcome)
  }

  private static func remoteName(_ name: String) -> String? {
    guard name.hasPrefix(prefix) else { return nil }
    return String(name.dropFirst(prefix.count))
  }

  private static func targets(in arguments: [String: JSONValue]) -> [String] {
    var result: [String] = []
    for key in ["target", "startTarget", "endTarget"] {
      if case .string(let target) = arguments[key] { result.append(target) }
    }
    if case .array(let fields) = arguments["fields"] {
      for field in fields {
        if case .object(let value) = field, case .string(let target) = value["target"] {
          result.append(target)
        }
      }
    }
    return result
  }

  private static func snapshotDetails(_ result: ToolResult)
    -> (references: Set<String>, tabs: Set<Int>)?
  {
    let text = textContent(result)
    guard text.utf8.count <= 1_024 * 1_024, text.contains("### Page\n- Page URL: "),
      text.contains("### Snapshot\n```yaml\n") || text.contains("### Modal state\n")
    else { return nil }
    var references: Set<String> = []
    if let start = text.range(of: "### Snapshot\n```yaml\n"),
      let end = text.range(of: "\n```", range: start.upperBound..<text.endIndex)
    {
      references = snapshotReferences(String(text[start.upperBound..<end.lowerBound]))
    }
    var tabMatches: [String] = []
    if let start = text.range(of: "### Open tabs\n"),
      let end = text.range(of: "\n### ", range: start.upperBound..<text.endIndex)
    {
      tabMatches = matches(#"(?m)^- (\d+): "#, in: String(text[start.upperBound..<end.lowerBound]))
    }
    let tabs = Set(tabMatches.compactMap(Int.init))
    return (references, tabs.isEmpty ? [0] : tabs)
  }

  private static func snapshotReferences(_ snapshot: String) -> Set<String> {
    guard let expression = try? NSRegularExpression(pattern: #"\[ref=((?:f\d+)?e\d+)\]"#)
    else { return [] }
    var references: Set<String> = []
    for line in snapshot.split(separator: "\n") {
      let text = String(line)
      for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        guard let attribute = Range(match.range, in: text),
          let reference = Range(match.range(at: 1), in: text)
        else { continue }
        var quoted = false
        var escaped = false
        var isAttribute = true
        for character in text[..<attribute.lowerBound] {
          if escaped {
            escaped = false
            continue
          }
          if quoted && character == "\\" {
            escaped = true
            continue
          }
          if character == "\"" { quoted.toggle() }
          if !quoted && character == ":" {
            isAttribute = false
            break
          }
        }
        if isAttribute && !quoted { references.insert(String(text[reference])) }
      }
    }
    return references
  }

  private static func isPredispatchStaleReference(
    _ result: ToolResult, name: String, arguments: [String: JSONValue]
  ) -> Bool {
    guard predispatchRefTools.contains(name) else { return false }
    let text = textContent(result)
    guard text.utf8.count <= 16_384, text.hasPrefix("### Error\n") else { return false }
    let errorText = String(text.dropFirst("### Error\n".count))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return targets(in: arguments).contains { target in
      let expected =
        "Ref \(target) not found in the current page snapshot. Try capturing new snapshot."
      return errorText == expected || errorText == "Error: \(expected)"
    }
  }

  private static func textContent(_ result: ToolResult) -> String {
    result.content.compactMap { item in
      guard case .text(let text) = item else { return nil }
      return text
    }.joined(separator: "\n")
  }

  private static func matches(_ pattern: String, in text: String) -> [String] {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
      guard let range = Range($0.range(at: 1), in: text) else { return nil }
      return String(text[range])
    }
  }
}
