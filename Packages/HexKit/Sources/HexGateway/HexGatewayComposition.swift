import HexCapabilities
import HexCore
import HexIPC
import HexMCP
import HexPersistence
import HexPersonality
import HexProviders
import HexRuntime

public enum HexGatewayComposition: Sendable {
  public static let moduleNames = [
    HexCoreModule.name,
    HexRuntimeModule.name,
    HexPersistenceModule.name,
    HexProvidersModule.name,
    HexCapabilitiesModule.name,
    HexMCPModule.name,
    HexPersonalityModule.name,
    HexIPCModule.name,
  ]
}
