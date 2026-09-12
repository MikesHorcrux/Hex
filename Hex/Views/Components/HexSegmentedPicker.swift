import SwiftUI

struct HexSegmentedPicker<Selection: Hashable>: View {
  let title: LocalizedStringKey
  let options: [Selection]
  @Binding var selection: Selection
  let label: (Selection) -> String

  var body: some View {
    Picker(title, selection: $selection) {
      ForEach(options, id: \.self) { option in
        Text(label(option)).tag(option)
      }
    }
    .pickerStyle(.segmented)
    .tint(HexBrandPalette.coral)
  }
}
