import Synchronization

struct InferenceStreamCursorControlState: Sendable {
  var isOpen = true
  var isReading = false
}
