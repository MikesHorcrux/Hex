import HexCore

public enum HexSelfInspectionToolError: Error, Equatable, Sendable {
  case reservedToolName
  case invalidArguments
}
