import HexCore

actor OpenAIInferenceEventRecorder {
  private var recordedEvents: [InferenceStreamEvent] = []

  func record(_ event: InferenceStreamEvent) {
    recordedEvents.append(event)
  }

  func events() -> [InferenceStreamEvent] {
    recordedEvents
  }
}
