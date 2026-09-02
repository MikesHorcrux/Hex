public enum CompositeToolExecutorError: Error, Equatable, Sendable {
  case invalidExecutorCount
  case tooManyTools
  case duplicateTool(String)
  case unknownTool
}
