import SwiftUI

/// Shared bucketed list. Pass `onArchiveToggle` to enable the per-row
/// archive/unarchive UX (the menu); pass `nil` for read-only rows (prompts).
struct BucketedLabelList: View {
    let groups: [PickerBucket]
    let onTap: (String) -> Void
    let onArchiveToggle: ((String) -> Void)?
    let onHoverChanged: ((String?) -> Void)?
    /// The label Enter will submit — rendered with a soft accent background
    /// so the user can see what's about to be selected.
    let highlightedLabel: String?
    /// Maps a label to its category color for the leading swatch. Defaults to
    /// accent so callers that don't care about colors need no change.
    let colorProvider: ((String) -> Color)?

    init(
        groups: [PickerBucket],
        onTap: @escaping (String) -> Void,
        onArchiveToggle: ((String) -> Void)? = nil,
        onHoverChanged: ((String?) -> Void)? = nil,
        highlightedLabel: String? = nil,
        colorProvider: ((String) -> Color)? = nil
    ) {
        self.groups = groups
        self.onTap = onTap
        self.onArchiveToggle = onArchiveToggle
        self.onHoverChanged = onHoverChanged
        self.highlightedLabel = highlightedLabel
        self.colorProvider = colorProvider
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.bucket.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                    ForEach(group.items) { item in
                        LabelRow(
                            label: item.label,
                            total: item.total,
                            isActive: item.isActive,
                            isSelected: item.isSelected,
                            isArchived: item.isArchived,
                            isHighlighted: item.label == highlightedLabel,
                            color: colorProvider?(item.label) ?? .accentColor,
                            onTap: { onTap(item.label) },
                            onArchiveToggle: onArchiveToggle.map { fn in
                                { fn(item.label) }
                            },
                            onHoverChanged: onHoverChanged
                        )
                    }
                }
            }
        }
    }
}
