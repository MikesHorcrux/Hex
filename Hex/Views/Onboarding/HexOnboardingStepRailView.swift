import SwiftUI

struct HexOnboardingStepRailView: View {
  let currentStep: HexOnboardingStep

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 12) {
        HexBrandMarkView(size: 54)
        VStack(alignment: .leading, spacing: 2) {
          Text("Hex")
            .font(.title2.weight(.bold))
            .foregroundStyle(HexBrandPalette.ink)
          Text("Your personal Mac agent")
            .font(.caption)
            .foregroundStyle(HexBrandPalette.mutedInk)
        }
      }
      .padding(.bottom, 30)

      VStack(alignment: .leading, spacing: 9) {
        ForEach(HexOnboardingStep.allCases, id: \.rawValue) { step in
          stepRow(step)
        }
      }

      Spacer(minLength: 24)

      VStack(alignment: .leading, spacing: 5) {
        Text("THINK. BUILD. ACT.")
          .font(.caption.weight(.bold))
          .tracking(1.1)
          .foregroundStyle(HexBrandPalette.accentInk)
        Text("Local-first, transparent, and made for one person: you.")
          .font(.caption)
          .foregroundStyle(HexBrandPalette.mutedInk)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(24)
    .frame(width: 238)
    .background(HexBrandPalette.sidebarTint)
  }

  private func stepRow(_ step: HexOnboardingStep) -> some View {
    let isCurrent = step == currentStep
    let isComplete = step.rawValue < currentStep.rawValue

    return HStack(spacing: 11) {
      ZStack {
        Circle()
          .fill(isCurrent ? HexBrandPalette.coral : HexBrandPalette.raisedSurface)
        Circle()
          .strokeBorder(
            isCurrent || isComplete ? HexBrandPalette.coral : HexBrandPalette.hairline,
            lineWidth: 1
          )
        if isComplete {
          Image(systemName: "checkmark")
            .font(.caption2.weight(.bold))
            .foregroundStyle(HexBrandPalette.accentInk)
        } else {
          Text("\(step.position)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(isCurrent ? Color.white : HexBrandPalette.mutedInk)
        }
      }
      .frame(width: 25, height: 25)

      Text(title(for: step))
        .font(.callout.weight(isCurrent ? .semibold : .regular))
        .foregroundStyle(isCurrent ? HexBrandPalette.ink : HexBrandPalette.mutedInk)

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 7)
    .background(
      isCurrent ? HexBrandPalette.raisedSurface.opacity(0.72) : Color.clear,
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "Step \(step.position) of \(HexOnboardingStep.allCases.count): \(title(for: step))"
    )
    .accessibilityValue(isCurrent ? "Current" : isComplete ? "Complete" : "Not started")
  }

  private func title(for step: HexOnboardingStep) -> String {
    switch step {
    case .welcome:
      "Welcome"
    case .inference:
      "AI model"
    case .workspace:
      "Workspace"
    case .tools:
      "Tools"
    case .permissions:
      "Mac access"
    case .personality:
      "Personality"
    case .ready:
      "Ready"
    }
  }
}
