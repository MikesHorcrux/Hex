import SwiftUI

struct HexResidentSetupLoadRetryView: View {
  let model: HexResidentSetupModel

  var body: some View {
    if model.needsLoadRetry {
      Button("Retry Loading Setup") {
        Task { await model.load() }
      }
      .buttonStyle(.hexSecondaryAction)
      .accessibilityIdentifier("residentRetryLoadButton")
    }
  }
}
