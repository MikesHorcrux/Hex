actor TestTaskCompletionProbe {
  private var completed = false

  func recordCompletion() {
    completed = true
  }

  func hasCompleted() -> Bool {
    completed
  }
}
