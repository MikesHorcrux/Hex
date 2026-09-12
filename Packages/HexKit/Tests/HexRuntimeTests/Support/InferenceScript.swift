import HexCore
import HexRuntime

enum InferenceScript: Sendable {
  case events([InferenceStreamEvent])
  case openingFailure
  case streamFailure
  case streamRuntimeFailure
  case suspend
  case suspendOpening
}
