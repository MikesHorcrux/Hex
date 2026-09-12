import Foundation
import HexCapabilities
import HexCore
import HexIPC

struct HexGatewayAuthorizationBrokerPendingRequest {
  let request: AuthorizationRequest
  let continuation: CheckedContinuation<AuthorizationPromptResponse, any Swift.Error>
}
