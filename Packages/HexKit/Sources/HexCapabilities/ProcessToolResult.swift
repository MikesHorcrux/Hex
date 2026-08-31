import Foundation
import HexCore

enum ProcessToolResult {
  static func result(
    _ result: ProcessExecutionResult,
    callID: ToolCallID
  ) -> ToolResult {
    let outputValue: JSONValue
    let encoding: String
    let sanitized: Bool
    if let text = ProcessPromptText.sanitizedUTF8Output(result.output) {
      outputValue = .string(text.text)
      encoding = text.sanitized ? "utf8_sanitized" : "utf8"
      sanitized = text.sanitized
    } else {
      outputValue = .string(result.output.base64EncodedString())
      encoding = "base64"
      sanitized = false
    }

    var output: [String: JSONValue] = [
      "output": outputValue,
      "output_encoding": .string(encoding),
      "output_sanitized": .boolean(sanitized),
      "output_bytes": .integer(Int64(result.output.count)),
      "duration_milliseconds": .integer(
        Int64(exactly: result.durationMilliseconds) ?? Int64.max
      ),
    ]
    let status: ToolResultStatus
    switch result.termination {
    case .exited(let code):
      output["termination"] = .string("exited")
      output["exit_code"] = .integer(Int64(code))
      status = code == 0 ? .success : .failure
    case .signaled(let signal):
      output["termination"] = .string("signaled")
      output["signal"] = .integer(Int64(signal))
      status = .failure
    case .timedOut:
      output["termination"] = .string("timed_out")
      status = .failure
    case .outputLimitExceeded:
      output["termination"] = .string("output_limit_exceeded")
      status = .failure
    }
    return ToolResult(toolCallID: callID, status: status, output: .object(output))
  }

  static func failure(
    _ error: Error,
    callID: ToolCallID
  ) throws -> ToolResult {
    if error is CancellationError {
      throw CancellationError()
    }
    let code: String
    switch error {
    case is ToolCallArgumentsError, ProcessExecutionError.invalidRequest:
      code = "invalid_arguments"
    case ProcessExecutionError.invalidConfiguration:
      code = "invalid_configuration"
    case ProcessExecutionError.authorizationRequired:
      code = "authorization_required"
    case ProcessExecutionError.authorizationStateUnavailable:
      code = "authorization_state_unavailable"
    case ProcessExecutionError.spawnFailed:
      code = "spawn_failed"
    case ProcessExecutionError.ioFailure:
      code = "io_failure"
    case ProcessExecutionError.cleanupFailed:
      // A cleanup failure leaves the process outcome uncertain. Keep it on the infrastructure
      // error path instead of returning a result that could claim the process was terminated.
      throw error
    default:
      throw error
    }
    return ToolResult(
      toolCallID: callID,
      status: .failure,
      output: .object(["error": .string(code)])
    )
  }
}
