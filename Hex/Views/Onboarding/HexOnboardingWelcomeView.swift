import SwiftUI

struct HexOnboardingWelcomeView: View {
  var body: some View {
    VStack(spacing: 20) {
      Image(systemName: "hexagon.fill")
        .font(.system(size: 68))
        .foregroundStyle(.tint)
        .symbolRenderingMode(.hierarchical)

      VStack(spacing: 8) {
        Text("Meet Hex")
          .font(.largeTitle.weight(.semibold))
        Text("One personal agent. Your whole Mac.")
          .font(.title3)
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 13) {
        Label("Your choice of OpenAI or local MLX inference", systemImage: "cpu")
        Label(
          "Coding, web, Mac, and MCP tools behind one runtime",
          systemImage: "wrench.and.screwdriver"
        )
        Label("Explicit permissions and a resident always-on gateway", systemImage: "hand.raised")
      }
      .font(.callout)
      .padding(18)
      .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
    .frame(maxWidth: 580, maxHeight: .infinity)
    .padding(40)
  }
}
