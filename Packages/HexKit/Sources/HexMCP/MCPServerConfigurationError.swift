public enum MCPServerConfigurationError: Error, Equatable, Sendable {
  case invalidServerID
  case invalidExecutable
  case invalidWorkingDirectory
  case invalidArguments
  case invalidEnvironment
  case invalidClientIdentity
  case invalidLimit
}
