import Foundation
import HexCore

/// Identity fields projected by the pinned Peekaboo MCP server, separate from UI text/instructions.
struct HexGatewayPeekabooObservation: Sendable {
  let snapshotID: String
  let processID: Int64
  let processStartIdentity: String
  let windowID: Int64
  let coordinateReference: String?

  static func capture(_ result: ToolResult, call: ToolCall) -> Self? {
    guard result.status == .success,
      case .object(let output) = result.output,
      output["server"] == .string("peekaboo"), output["isError"] == .boolean(false),
      case .object(let metadata) = output["_meta"],
      case .object(let target) = metadata["target_receipt"],
      case .integer(let pid) = target["pid"], (1...Int64(Int32.max)).contains(pid),
      case .integer(let window) = target["window_id"], (1...Int64(UInt32.max)).contains(window),
      case .string(let started) = target["process_start_identity_decimal"],
      !started.isEmpty, started.utf8.count <= 20,
      started.utf8.allSatisfy({ (48...57).contains($0) }),
      let processGeneration = UInt64(started), processGeneration > 0,
      call.arguments["app_target"] == .string("PID:\(pid)"),
      call.arguments["window_id"] == .integer(window),
      metadata["mutation_dispatched"] != .boolean(true),
      metadata["truncated"] != .boolean(true)
    else { return nil }
    if let identity = metadata["target_identity"] {
      guard case .object(let identity) = identity,
        identity["pid"] == .integer(pid), identity["window_id"] == .integer(window),
        identity["process_start_identity_decimal"] == .string(started)
      else { return nil }
    }

    let name = HexGatewayPeekabooCallPolicy.remoteName(call.name)
    guard output["tool"] == name.map(JSONValue.string) else { return nil }
    let snapshot: String
    let coordinateReference: String?
    if name == "see" {
      guard result.content.contains(where: { if case .image = $0 { true } else { false } }),
        case .object(let coordinates) = metadata["coordinate_context"],
        coordinates["version"] == .integer(1),
        let reference = boundedIdentifier(coordinates["reference_id"]),
        case .object(let coordinateWindow) = coordinates["window"],
        coordinateWindow["window_id"] == .integer(window)
      else { return nil }
      snapshot = reference
      coordinateReference = reference
    } else if name == "inspect_ui" {
      // 4.2.2 does not project snapshot_id into external MCP metadata for AX-only inspection.
      // An explicit existing snapshot is request-correlated and refreshed by InspectUITool.
      // A newly allocated implicit snapshot cannot be recovered safely from descriptive text.
      guard let requested = boundedIdentifier(call.arguments["snapshot"]) else { return nil }
      snapshot = requested
      coordinateReference = nil
    } else {
      return nil
    }
    return Self(
      snapshotID: snapshot, processID: pid, processStartIdentity: started,
      windowID: window, coordinateReference: coordinateReference)
  }

  func boundArguments(_ arguments: [String: JSONValue], tool: String) -> [String: JSONValue]? {
    var result = arguments
    result.removeValue(forKey: "hex_observation_id")
    // These selectors can resolve another window, process, or global desktop after observation.
    for key in ["window_title", "window_index", "title", "index", "to_app", "cycle", "all"] {
      guard result[key] == nil else { return nil }
    }
    guard result["foreground"] != .boolean(true), result["background"] != .boolean(false),
      result["capture_focus"] == nil || result["capture_focus"] == .string("background")
    else { return nil }
    for key in ["pid", "window_id"] {
      let expected: JSONValue = .integer(key == "pid" ? processID : windowID)
      guard result[key] == nil || result[key] == expected else { return nil }
    }
    var processSelectors = ["app", "app_target", "bundleId"]
    if tool == "app" { processSelectors += ["name", "to"] }
    for key in processSelectors {
      guard result[key] == nil || result[key] == .string("PID:\(processID)") else { return nil }
    }
    guard result["snapshot"] == nil || result["snapshot"] == .string(snapshotID),
      result["coordinate_reference"] == nil
        || result["coordinate_reference"] == coordinateReference.map(JSONValue.string)
    else { return nil }

    if HexGatewayPeekabooCallPolicy.snapshotActions.contains(tool) {
      result["snapshot"] = .string(snapshotID)
      if result["coords"] != nil {
        guard let coordinateReference else { return nil }
        result["coordinate_reference"] = .string(coordinateReference)
      }
      return result
    }
    switch tool {
    case "window":
      result["app"] = .string("PID:\(processID)")
      result["window_id"] = .integer(windowID)
    case "dialog", "paste":
      result.removeValue(forKey: "app")
      result["pid"] = .integer(processID)
      result["window_id"] = .integer(windowID)
    case "menu":
      result["app"] = .string("PID:\(processID)")
    case "app":
      guard result["action"] != .string("open"), result["action"] != .string("relaunch"),
        result["newInstance"] != .boolean(true), result["openTargets"] == nil
      else { return nil }
      if result["action"] == .string("switch") {
        result["to"] = .string("PID:\(processID)")
      } else {
        result["name"] = .string("PID:\(processID)")
      }
    case "space":
      guard result["action"] == .string("move-window"), result["follow"] != .boolean(true)
      else { return nil }
      result["app"] = .string("PID:\(processID)")
      result["window_id"] = .integer(windowID)
    default:
      // Clipboard/Dock/global-pointer changes do not have an exact-window receipt contract.
      return nil
    }
    return result
  }

  private static func boundedIdentifier(_ value: JSONValue?) -> String? {
    guard case .string(let value) = value, !value.isEmpty, value.utf8.count <= 256,
      value.utf8.allSatisfy({ (33...126).contains($0) })
    else { return nil }
    return value
  }
}
