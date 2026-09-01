import Foundation

/// Canonical identity shared by the resident executable, the app's XPC transport, and the future
/// launch-agent template. Keeping these values in the package avoids silently drifting Mach names
/// between lifecycle glue and client code.
public enum HexGatewayServiceIdentity {
  public static let machServiceName = "com.lunarmothstudios.hex.gateway"
  public static let launchAgentLabel = "com.lunarmothstudios.hex.gateway"
  public static let bundledExecutablePath = "Contents/Resources/HexGateway"

  private init() {}
}
