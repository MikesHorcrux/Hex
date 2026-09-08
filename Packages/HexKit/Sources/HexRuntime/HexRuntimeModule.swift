import HexCore

public enum HexRuntimeModule: Sendable {
  public static let name = "HexRuntime"
  public static let dependencies = [HexCoreModule.name]
}
