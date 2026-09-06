import SwiftUI

struct HexOnboardingWelcomeView: View {
  var body: some View {
    ZStack {
      HexBrandBackdrop()

      ScrollView {
        VStack(spacing: 18) {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
              heroCopy
                .frame(maxWidth: 300, alignment: .leading)
              Spacer(minLength: 0)
              HexMascotView(size: 205)
            }

            VStack(alignment: .leading, spacing: 10) {
              HexMascotView(size: 160)
                .frame(maxWidth: .infinity)
              heroCopy
            }
          }

          VStack(alignment: .leading, spacing: 0) {
            featureRow(
              "Choose the model",
              detail: "Use ChatGPT, an API key, or a local model.",
              systemImage: "cpu"
            )
            Divider()
              .overlay(HexBrandPalette.deepPlum.opacity(0.12))
            featureRow(
              "Give it useful tools",
              detail: "Browser and screen control install automatically when enabled.",
              systemImage: "wrench.and.screwdriver"
            )
            Divider()
              .overlay(HexBrandPalette.deepPlum.opacity(0.12))
            featureRow(
              "Stay in control",
              detail: "Every permission is visible, reversible, and still governed by macOS.",
              systemImage: "hand.raised"
            )
          }
          .padding(.horizontal, 18)
          .background(
            HexBrandPalette.cream.opacity(0.96),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
          )
          .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
              .strokeBorder(HexBrandPalette.deepPlum.opacity(0.12), lineWidth: 1)
          }
          .shadow(color: HexBrandPalette.deepPlum.opacity(0.13), radius: 9, y: 4)
        }
        .frame(maxWidth: 610)
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
      }
    }
  }

  private var heroCopy: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text("MEET\nHEX.")
        .font(.system(size: 58, weight: .black, design: .default).width(.condensed))
        .lineSpacing(-7)
        .foregroundStyle(HexBrandPalette.cream)
        .accessibilityAddTraits(.isHeader)

      VStack(alignment: .leading, spacing: 5) {
        Text("ONE PERSONAL AGENT.\nYOUR WHOLE MAC.")
          .font(.headline.weight(.black))
          .tracking(0.8)

        Text(
          "Hex stays on your Mac and brings coding, browser, and Mac control into one clear conversation."
        )
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

  private func featureRow(
    _ title: String,
    detail: String,
    systemImage: String
  ) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(HexBrandPalette.coral)
        .frame(width: 30, height: 30)
        .background(HexBrandPalette.softCoral, in: Circle())
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.callout.weight(.semibold))
          .foregroundStyle(HexBrandPalette.deepPlum)
        Text(detail)
          .font(.caption)
          .foregroundStyle(HexBrandPalette.deepPlum.opacity(0.72))
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
    .padding(.vertical, 13)
  }
}
