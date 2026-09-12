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
      "total_output_bytes": .integer(result.totalOutputBytes),
      "preview_truncated": .boolean(result.totalOutputBytes > Int64(result.output.count)),
      "output_complete": .boolean(result.outputIsComplete),
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
    case .cancelled:
      output["termination"] = .string("cancelled")
      output["message"] = .string(
        "The command was cancelled after it started and its process group was stopped. Captured output is partial. Do not repeat it automatically; it may already have changed files or external state."
      )
      status = .failure
    case .outputLimitExceeded:
      output["termination"] = .string("output_limit_exceeded")
      status = .failure
    case .outputCaptureFailed:
      output["termination"] = .string("output_capture_failed")
      status = .failure
    }
    if let failure = result.outputCaptureFailure {
      output["output_capture_error"] = .string(failure.rawValue)
    }
    if result.outputCaptureFailure != nil || result.termination == .outputLimitExceeded {
      output["message"] = .string(
        "The command ran, but Hex could not preserve all of its output. Its reported exit or termination remains authoritative. Do not repeat the command automatically to recover missing output; it may already have changed files or external state."
      )
    }
    if let artifact = result.outputArtifact {
      output["artifact_output_bytes"] = .integer(artifact.byteCount)
      output["output_location"] = .string("artifact")
    } else {
      output["output_location"] = .string("inline")
    }
    return ToolResult(
      toolCallID: callID, status: result.outputCaptureFailure == nil ? status : .failure,
      output: .object(output), artifacts: result.outputArtifact.map { [$0] } ?? [],
      requiresUserAttention: result.outputCaptureFailure != nil
        || result.termination == .outputCaptureFailed || result.termination == .outputLimitExceeded,
      executionOutcome: knownExit(result.termination) ? .completed : nil)
  }

  private static func knownExit(_ termination: ProcessTermination) -> Bool {
    if case .exited = termination { return true }
    return false
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
    case ProcessExecutionError.authorizationDetailsTooLarge:
      code = "authorization_details_too_large"
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
    case ProcessExecutionError.outputCaptureUnavailable:
      code = "output_capture_unavailable"
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
