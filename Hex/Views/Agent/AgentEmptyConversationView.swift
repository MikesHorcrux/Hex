import SwiftUI

struct AgentEmptyConversationView: View {
  let onPromptSuggestion: (String) -> Void

  var body: some View {
    VStack(spacing: 20) {
      Spacer(minLength: 24)
      HexAppIconView(size: 52)
      Text("What would you like to do?")
        .font(.system(size: 26, weight: .medium))
        .foregroundStyle(HexBrandPalette.ink)
        .multilineTextAlignment(.center)
        .accessibilityAddTraits(.isHeader)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) { suggestions }
        VStack(spacing: 10) { suggestions }
      }
      Spacer(minLength: 24)
      Spacer(minLength: 0)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
  }

  private var suggestions: some View {
    Group {
      suggestion(
        "Explore a project", icon: "folder",
        prompt: "Inspect this project and explain the most important things I should know.")
      suggestion(
        "Find something", icon: "magnifyingglass", prompt: "Find reliable information about: ")
      suggestion("Help on this Mac", icon: "desktopcomputer", prompt: "Help me do this on my Mac: ")
    }
  }

  private func suggestion(_ title: String, icon: String, prompt: String) -> some View {
    Button {
      onPromptSuggestion(prompt)
    } label: {
      Label(title, systemImage: icon)
        .font(.callout)
        .foregroundStyle(HexBrandPalette.mutedInk)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(HexBrandPalette.surface, in: Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityHint("Places a suggested request in the message field")
  }
}
