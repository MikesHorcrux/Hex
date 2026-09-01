public enum HostToolExecutorError: Error, Equatable, Sendable {
  case invalidDefinition
  case duplicateName
  case unknownTool
}
