import HexCore

/// Reads only canonical helper metadata; descriptive UI content never asserts dispatch safety.
enum HexGatewayPeekabooDispatchReceipt: Equatable {
  case refused(reason: String)
  case unnecessary
  case dispatched
  case uncertain

  static func parse(_ result: ToolResult) -> Self {
    guard case .object(let output) = result.output,
      output["server"] == .string("peekaboo"),
      case .object(let meta) = output["_meta"],
      meta["route"] == .string("local") || meta["route"] == .string("bridge")
    else { return .uncertain }
    if meta["dispatch_state"] == .string("none"),
      meta["mutation_dispatched"] == .boolean(false)
    {
      if result.status == .failure, meta["state"] == .string("refused"),
        meta["effect"] == .string("refused"), meta["evidence"] == .string("request_refused"),
        meta["retry_safe"] == .boolean(true), meta["retry_safety"] == .string("safe"),
        meta["requires_fresh_observation"] == .boolean(false),
        case .string(let reason) = meta["refusal_reason"],
        let escalation = refusalEscalations[reason], meta["escalation"] == .string(escalation)
      {
        return .refused(reason: reason)
      }
      if result.status == .success, meta["state"] == .string("confirmed_no_change"),
        meta["effect"] == .string("confirmed"), meta["evidence"] == .string("verified_no_change"),
        meta["retry_safety"] == .string("not_applicable"), meta["escalation"] == .string("none"),
        meta["retry_safe"] == .boolean(false), meta["requires_fresh_observation"] == .boolean(false)
      {
        return .unnecessary
      }
      return .uncertain
    }
    guard meta["dispatch_state"] == .string("dispatched"),
      meta["mutation_dispatched"] == .boolean(true), meta["retry_safe"] == .boolean(false)
    else { return .uncertain }
    if result.status == .success, meta["state"] == .string("confirmed_change"),
      meta["effect"] == .string("confirmed"),
      meta["evidence"] == .string("verified_change"),
      meta["retry_safety"] == .string("not_applicable"), meta["escalation"] == .string("none"),
      meta["requires_fresh_observation"] == .boolean(false)
    {
      return .dispatched
    }
    // Peekaboo reports unverified delivery with isError=true. The canonical receipt
    // still proves dispatch and explicitly permits observation, never blind replay.
    if meta["state"] == .string("dispatched_unverified"), meta["effect"] == .string("unverifiable"),
      meta["evidence"] == .string("delivery_accepted")
        || meta["evidence"] == .string("operation_still_running"),
      meta["retry_safety"] == .string("unsafe"),
      meta["escalation"] == .string("observe_before_retry"),
      meta["requires_fresh_observation"] == .boolean(true)
    {
      return .dispatched
    }
    return .uncertain
  }

  private static let refusalEscalations = [
    "invalid_request": "correct_request", "permission_denied": "grant_permission",
    "target_unavailable": "refresh_target", "transport_session_unavailable": "reconnect_session",
    "request_cancelled": "none", "runtime_incompatible": "update_runtime",
    "foreground_consent_required": "correct_request", "operation_unsupported": "correct_request",
  ]
}
