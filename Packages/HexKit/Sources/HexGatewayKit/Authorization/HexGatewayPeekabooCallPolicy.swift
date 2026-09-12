import HexCore

/// Host-owned classification of the pinned Peekaboo 4.3.3 catalog. Server descriptions are data.
enum HexGatewayPeekabooCallPolicy {
  static let prefix = "mcp_8_peekaboo_"
  static let excluded = Set(["agent", "analyze", "browser"])
  static let snapshotActions = Set([
    "action", "click", "drag", "move", "press", "scroll", "set_value", "type",
  ])

  static func remoteName(_ name: String) -> String? {
    guard name.hasPrefix(prefix) else { return nil }
    return String(name.dropFirst(prefix.count))
  }

  static func classify(_ name: String, arguments: [String: JSONValue])
    -> HexGatewayPeekabooCallPolicyKind
  {
    switch name {
    case "see", "inspect_ui":
      return arguments["web_focus"] == .boolean(true) ? .unsupported : .observation
    case "permissions", "sleep", "verify_state":
      return .read
    case "image", "capture":
      return arguments["capture_focus"] == nil
        || arguments["capture_focus"] == .string("background")
        ? .read : .mutation
    case "action", "type", "move", "press", "click", "scroll", "paste", "drag", "set_value":
      return .mutation
    case "app":
      return actionKind(
        arguments, reads: ["list"],
        mutations: [
          "launch", "open", "quit", "relaunch", "focus", "hide", "unhide", "switch",
        ])
    case "window":
      return actionKind(
        arguments, reads: ["list"],
        mutations: [
          "close", "minimize", "restore", "maximize", "move", "resize", "set-bounds", "focus",
        ])
    case "dialog":
      return actionKind(
        arguments, reads: ["list"], mutations: ["click", "input", "file", "dismiss"])
    case "space":
      return actionKind(arguments, reads: ["list"], mutations: ["switch", "move-window"])
    case "dock":
      return actionKind(
        arguments, reads: ["list"], mutations: ["launch", "right-click", "hide", "show"])
    case "menu":
      if arguments["foreground"] == .boolean(true) { return .mutation }
      return actionKind(arguments, reads: ["list"], mutations: ["click"])
    case "clipboard":
      return actionKind(arguments, reads: ["get", "save"], mutations: ["set", "clear", "restore"])
    default:
      return .unsupported
    }
  }

  static func isListed(_ name: String) -> Bool {
    let names = Set([
      "action", "sleep", "type", "space", "verify_state", "move", "press", "dialog",
      "clipboard", "see", "permissions", "app", "dock", "click", "scroll", "image",
      "inspect_ui", "window", "paste", "drag", "set_value", "menu", "capture",
    ])
    return names.contains(name)
  }

  private static func actionKind(
    _ arguments: [String: JSONValue], reads: Set<String>, mutations: Set<String>
  ) -> HexGatewayPeekabooCallPolicyKind {
    guard case .string(let action) = arguments["action"] else { return .unsupported }
    if reads.contains(action) { return .read }
    return mutations.contains(action) ? .mutation : .unsupported
  }
}
