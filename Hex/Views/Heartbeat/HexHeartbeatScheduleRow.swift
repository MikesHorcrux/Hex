import HexIPC
import SwiftUI

struct HexHeartbeatScheduleRow: View {
  let schedule: GatewayHeartbeatSchedule
  let isBusy: Bool
  let onTogglePause: () -> Void
  let onRemove: () -> Void
  var onViewResults: () -> Void = {}

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: schedule.isPaused ? "pause.circle" : "calendar.badge.clock")
        .font(.title3)
        .foregroundStyle(schedule.isPaused ? Color.secondary : Color.accentColor)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(schedule.name)
            .font(.headline)
          Text(schedule.isPaused ? "Paused" : "Active")
            .font(.caption.weight(.medium))
            .foregroundStyle(
              schedule.isPaused ? Color.secondary : HexBrandPalette.successInk
            )
        }

        Text(schedule.instruction)
          .font(.callout)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 12) {
          Label(intervalDescription, systemImage: "repeat")
          Label {
            Text(schedule.nextDueAt, style: .relative)
          } icon: {
            Image(systemName: "clock")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        if let outcome = schedule.lastOutcome {
          Label {
            Text("Last \(outcomeDescription(outcome))")
          } icon: {
            Image(systemName: outcomeSymbol(outcome))
          }
          .font(.caption)
          .foregroundStyle(outcomeColor(outcome))
          Text(outcome.completedAt, style: .relative)
            .font(.caption).foregroundStyle(.secondary)
          if let failure = outcome.failureMessage {
            Text(failure).font(.caption).foregroundStyle(.orange).lineLimit(2)
          }
        }
      }

      Spacer(minLength: 8)

      VStack(alignment: .trailing, spacing: 6) {
        Button("View results", action: onViewResults)
          .buttonStyle(.link).font(.caption)
          .accessibilityIdentifier("heartbeatResults-\(schedule.id.uuidString)")
        Button(schedule.isPaused ? "Resume" : "Pause", action: onTogglePause)
          .buttonStyle(.bordered)
          .controlSize(.small)
          .disabled(isBusy)
          .accessibilityIdentifier("heartbeatPause-\(schedule.id.uuidString)")
        Button("Remove", role: .destructive, action: onRemove)
          .buttonStyle(.link)
          .font(.caption)
          .disabled(isBusy)
          .accessibilityIdentifier("heartbeatRemove-\(schedule.id.uuidString)")
      }
    }
    .padding(12)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .contain)
  }

  private var intervalDescription: String {
    let totalMinutes = max(1, Int((schedule.intervalSeconds / 60).rounded()))
    if totalMinutes.isMultiple(of: 60) {
      let hours = totalMinutes / 60
      return hours == 1 ? "Every hour" : "Every \(hours) hours"
    }
    return totalMinutes == 1 ? "Every minute" : "Every \(totalMinutes) minutes"
  }

  private func outcomeDescription(_ outcome: GatewayHeartbeatOutcome) -> String {
    switch outcome.kind {
    case .succeeded:
      "succeeded"
    case .failed:
      "failed"
    case .cancelled:
      "cancelled"
    case .skipped:
      "skipped"
    case .interrupted:
      "interrupted"
    }
  }

  private func outcomeSymbol(_ outcome: GatewayHeartbeatOutcome) -> String {
    switch outcome.kind {
    case .succeeded:
      "checkmark.circle"
    case .failed:
      "xmark.circle"
    case .cancelled, .interrupted:
      "exclamationmark.circle"
    case .skipped:
      "forward.end"
    }
  }

  private func outcomeColor(_ outcome: GatewayHeartbeatOutcome) -> Color {
    switch outcome.kind {
    case .succeeded:
      HexBrandPalette.successInk
    case .failed, .cancelled, .interrupted:
      .orange
    case .skipped:
      .secondary
    }
  }
}
