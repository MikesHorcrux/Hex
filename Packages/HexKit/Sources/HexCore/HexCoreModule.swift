/// Stable, dependency-free domain contracts. HexCore values may be journaled or cross process
/// boundaries and must never contain credentials or other secrets.
public enum HexCoreModule: Sendable {
  public static let name = "HexCore"
  public static let dependencies: [String] = []
}
