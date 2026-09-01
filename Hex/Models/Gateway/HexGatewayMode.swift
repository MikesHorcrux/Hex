/// Environment-selectable gateway modes. Resident XPC is the safe default; the in-process mode
/// requires a separate explicit opt-in and a complete valid developer configuration.
nonisolated enum HexGatewayMode: String, Equatable, Sendable {
  case residentXPC = "xpc"
  case developerInProcess = "in-process"
}
