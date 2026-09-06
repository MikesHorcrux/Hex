import SwiftUI

struct AgentEmptyConversationView: View {
  let onPromptSuggestion: (String) -> Void

  var body: some View {
    ZStack {
      HexBrandBackdrop()

      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 22) {
              heroCopy
                .frame(maxWidth: 320, alignment: .leading)
              Spacer(minLength: 0)
              HexMascotView(size: 220)
            }

            VStack(alignment: .leading, spacing: 12) {
              HexMascotView(size: 170)
                .frame(maxWidth: .infinity)
              heroCopy
            }
          }

          ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
              promptButton(
                kicker: "THINK",
                title: "Explore a project",
                systemImage: "folder.fill",
                prompt: "Inspect this project and explain the most important things I should know."
              )
              promptButton(
                kicker: "BUILD",
                title: "Find something",
                systemImage: "globe.americas.fill",
                prompt: "Find reliable information about: "
              )
              promptButton(
                kicker: "ACT",
                title: "Help on this Mac",
                systemImage: "desktopcomputer",
                prompt: "Help me do this on my Mac: "
              )
            }

            VStack(spacing: 9) {
              promptButton(
                kicker: "THINK",
                title: "Explore a project",
                systemImage: "folder.fill",
                prompt: "Inspect this project and explain the most important things I should know."
              )
              promptButton(
                kicker: "BUILD",
                title: "Find something",
                systemImage: "globe.americas.fill",
                prompt: "Find reliable information about: "
              )
              promptButton(
                kicker: "ACT",
                title: "Help on this Mac",
                systemImage: "desktopcomputer",
                prompt: "Help me do this on my Mac: "
              )
            }
          }
        }
        .frame(maxWidth: 820)
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
  }

  private var heroCopy: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("THINK.\nBUILD.\nACT.")
        .font(.system(size: 58, weight: .black, design: .default).width(.condensed))
        .lineSpacing(-7)
        .foregroundStyle(HexBrandPalette.cream)
        .accessibilityAddTraits(.isHeader)

      VStack(alignment: .leading, spacing: 5) {
        Text("ONE PERSONAL AGENT. YOUR WHOLE MAC.")
          .font(.headline.weight(.black))
          .tracking(0.9)

        Text("Tell Hex what you want to get done, then stay in control while it works.")
          .font(.callout.weight(.medium))
          .fixedSize(horizontal: false, vertical: true)
      }
      .foregroundStyle(HexBrandPalette.deepPlum)
      .padding(10)
      .background(
        HexBrandPalette.cream.opacity(0.92),
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
    }
  }

  private func promptButton(
    kicker: String,
    title: String,
    systemImage: String,
    prompt: String
  ) -> some View {
    Button {
      onPromptSuggestion(prompt)
    } label: {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: systemImage)
          .font(.callout.weight(.bold))
          .foregroundStyle(HexBrandPalette.coral)
          .frame(width: 28, height: 28)
          .background(HexBrandPalette.softCoral, in: Circle())
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 2) {
          Text(kicker)
            .font(.caption2.weight(.black))
            .tracking(1)
            .foregroundStyle(HexBrandPalette.coralPressed)
          Text(title)
            .font(.callout.weight(.semibold))
            .foregroundStyle(HexBrandPalette.deepPlum)
        }

        Spacer(minLength: 0)
      }
      .padding(12)
      .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
      .background(
        HexBrandPalette.cream.opacity(0.96),
        in: RoundedRectangle(cornerRadius: 15, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
          .strokeBorder(HexBrandPalette.deepPlum.opacity(0.13), lineWidth: 1)
      }
      .shadow(color: HexBrandPalette.deepPlum.opacity(0.12), radius: 6, y: 3)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(kicker): \(title)")
    .accessibilityHint("Places a suggested request in the message field")
  }
}
