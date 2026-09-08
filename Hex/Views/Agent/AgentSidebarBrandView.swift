import SwiftUI

struct AgentSidebarBrandView: View {
  let onNewConversation: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        HexAppIconView(size: 50)

        VStack(alignment: .leading, spacing: 1) {
          Text("HEX")
            .font(.title2.weight(.black))
            .tracking(1.8)
            .foregroundStyle(HexBrandPalette.ink)
          Text("One personal agent.\nYour whole Mac.")
            .font(.caption)
            .foregroundStyle(HexBrandPalette.mutedInk)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Button(action: onNewConversation) {
        Label("New conversation", systemImage: "plus")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.hexPrimaryAction)
      .keyboardShortcut("n", modifiers: [.command])
      .accessibilityIdentifier("newConversationButton")
    }
    .padding(.horizontal, 14)
    .padding(.top, 14)
    .padding(.bottom, 12)
    .background(HexBrandPalette.softCoral.opacity(0.92))
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(HexBrandPalette.deepPlum.opacity(0.1))
        .frame(height: 1)
    }
  }
}
