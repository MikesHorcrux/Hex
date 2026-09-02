import HexIPC
import SwiftUI

struct HexHeartbeatScheduleEditorView: View {
  @Environment(\.dismiss) private var dismiss

  @State private var name = ""
  @State private var instruction = ""
  @State private var intervalMinutes = "60"
  @State private var nextDueAt = Date().addingTimeInterval(60 * 60)
  @State private var maxCatchUpOccurrences = 1
  @State private var isPaused = false
  @State private var validationMessage: String?
  @State private var isSaving = false

  let onSave: (GatewayHeartbeatScheduleRequest) async -> Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("New heartbeat")
        .font(.title2.weight(.semibold))

      Form {
        TextField("Name", text: $name)
          .textFieldStyle(.roundedBorder)
        TextField("Runs every (minutes)", text: $intervalMinutes)
          .textFieldStyle(.roundedBorder)
        DatePicker("First run", selection: $nextDueAt)
        Stepper(
          "Catch up at most \(maxCatchUpOccurrences) missed run\(maxCatchUpOccurrences == 1 ? "" : "s")",
          value: $maxCatchUpOccurrences,
          in: 1...GatewayHeartbeatSchedule.maximumCatchUpOccurrences
        )
        Toggle("Start paused", isOn: $isPaused)
        VStack(alignment: .leading, spacing: 6) {
          Text("Instruction")
            .font(.headline)
          TextEditor(text: $instruction)
            .font(.body)
            .frame(minHeight: 120)
            .overlay {
              RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.quaternary)
            }
        }
      }

      if let validationMessage {
        Text(validationMessage)
          .font(.callout)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        Button("Create") {
          save()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(isSaving)
      }
    }
    .padding(20)
    .frame(width: 480)
  }

  private func save() {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      validationMessage = "Give this heartbeat a name."
      return
    }
    guard !trimmedInstruction.isEmpty else {
      validationMessage = "Add an instruction for Hex to run."
      return
    }
    guard let minutes = Double(intervalMinutes), minutes.isFinite, minutes > 0 else {
      validationMessage = "The interval must be a positive number of minutes."
      return
    }
    let intervalSeconds = minutes * 60
    guard intervalSeconds.isFinite,
      intervalSeconds <= GatewayHeartbeatSchedule.maximumIntervalSeconds
    else {
      validationMessage = "The interval cannot be longer than one year."
      return
    }
    guard nextDueAt.timeIntervalSinceReferenceDate.isFinite else {
      validationMessage = "Choose a valid first-run date."
      return
    }

    validationMessage = nil
    isSaving = true
    let request = GatewayHeartbeatScheduleRequest(
      id: UUID(),
      name: trimmedName,
      instruction: trimmedInstruction,
      intervalSeconds: intervalSeconds,
      nextDueAt: nextDueAt,
      maxCatchUpOccurrences: maxCatchUpOccurrences,
      isPaused: isPaused
    )
    Task { @MainActor in
      let didSave = await onSave(request)
      isSaving = false
      if didSave {
        dismiss()
      }
    }
  }
}
