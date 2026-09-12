import HexCore

public enum HexIPCModule: Sendable {
  public static let name = "HexIPC"
  public static let dependencies = [HexCoreModule.name]
}
