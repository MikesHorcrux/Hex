import SwiftUI

struct HexPersonalityProfileCollectionView: View {
  let title: String
  let prompt: String
  let fieldIdentifier: String
  @Binding var text: String

  var body: some View {
    Section {
      TextEditor(text: $text)
        .font(.body)
        .frame(minHeight: 72, idealHeight: 96)
        .overlay(alignment: .topLeading) {
          if text.isEmpty {
            Text(prompt)
              .foregroundStyle(.tertiary)
              .padding(.top, 8)
              .padding(.leading, 5)
              .allowsHitTesting(false)
          }
        }
        .accessibilityIdentifier(fieldIdentifier)

      Text("One entry per line. Entries are kept as user-managed profile data.")
        .font(.caption)
        .foregroundStyle(.secondary)
    } header: {
      Text(title)
    }
  }
}
