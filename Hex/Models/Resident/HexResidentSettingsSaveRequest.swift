import Foundation
import HexCore
import HexIPC
import HexMCP
import Observation

struct HexResidentSettingsSaveRequest: Sendable {
  let settings: HexResidentRuntimeSettings
  let apiKey: String
  let mcpSecretChanges: [HexMCPSecretChange]
}
