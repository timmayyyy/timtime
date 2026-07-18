import SwiftUI

/// Simple naming screen for the fixed color palette. The colors themselves are
/// static — the only thing the user changes is each color's name (e.g. Blue →
/// "Personal", Green → "Professional"). Reached from the selection bar's
/// "Manage…" button and shown in place of the normal menu content.
struct ManageColorsView: View {
    @ObservedObject var tracker: Tracker
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Name Colors").font(.callout).bold()
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(.borderless)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(tracker.colorCategories) { category in
                        HStack(spacing: 10) {
                            Circle().fill(category.color).frame(width: 14, height: 14)
                            ColorNameField(initial: category.name) { newName in
                                tracker.renameColorCategory(id: category.id, name: newName)
                            }
                        }
                    }
                }
                .padding(.trailing, 2)
            }
            .frame(maxHeight: 360)

            Text("The first color is the default for new labels.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Name editor with its own local state so typing never fights the @Published
/// category array (which would jump the cursor). Commits each edit up to the
/// tracker as the user types.
private struct ColorNameField: View {
    let initial: String
    let onChange: (String) -> Void
    @State private var text: String

    init(initial: String, onChange: @escaping (String) -> Void) {
        self.initial = initial
        self.onChange = onChange
        _text = State(initialValue: initial)
    }

    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.plain)
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .onChange(of: text) { _, newValue in onChange(newValue) }
    }
}
