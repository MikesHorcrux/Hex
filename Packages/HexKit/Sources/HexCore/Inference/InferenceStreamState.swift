import Synchronization

enum InferenceStreamState: Sendable {
  case idle
  case consuming(InferenceStreamCursorControl)
  case cancelled
  case finished
}
