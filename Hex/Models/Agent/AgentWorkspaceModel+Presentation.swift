import Foundation

extension AgentWorkspaceModel {
  /// The canonical transcript/cursor still apply and persist every event together. Rendering is a
  /// separate immutable snapshot, capped at 20 Hz so live tokens and journal replay cannot require
  /// a full text layout per event. First rows, final text, cancellation and selection flush at once.
  func scheduleTranscriptPresentation() {
    guard presentedTranscript.count == transcript.count,
      presentedTranscript.last?.id == transcript.last?.id, transcript.last?.isStreaming == true
    else {
      publishTranscript()
      return
    }
    guard transcriptPresentationTask == nil else { return }
    transcriptPresentationTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
      guard let self else { return }
      publishTranscript()
    }
  }

  private func publishTranscript() {
    transcriptPresentationTask?.cancel()
    transcriptPresentationTask = nil
    presentedTranscript = transcript
  }
}
