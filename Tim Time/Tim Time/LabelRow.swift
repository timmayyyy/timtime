import SwiftUI

/// Shared row used by the menu's day breakdown and the check-in prompt's picker.
/// Pass `onArchiveToggle` to enable the hover archive/unarchive UX; pass `nil`
/// for a read-only tappable row (the prompt's confirm path).
struct LabelRow: View {
    let label: String
    let total: TimeInterval
    let isActive: Bool
    let isSelected: Bool
    let isArchived: Bool
    /// True when this row is the top filter match — soft background tells the
    /// user that Enter will pick this row.
    let isHighlighted: Bool
    let onTap: () -> Void
    let onArchiveToggle: (() -> Void)?
    /// Fired with the label name on hover-in and nil on hover-out so a parent
    /// view can highlight matching timeline segments.
    let onHoverChanged: ((String?) -> Void)?

    @State private var hovering = false
    @State private var confirming = false

    init(
        label: String,
        total: TimeInterval,
        isActive: Bool,
        isSelected: Bool,
        isArchived: Bool = false,
        isHighlighted: Bool = false,
        onTap: @escaping () -> Void,
        onArchiveToggle: (() -> Void)? = nil,
        onHoverChanged: ((String?) -> Void)? = nil
    ) {
        self.label = label
        self.total = total
        self.isActive = isActive
        self.isSelected = isSelected
        self.isArchived = isArchived
        self.isHighlighted = isHighlighted
        self.onTap = onTap
        self.onArchiveToggle = onArchiveToggle
        self.onHoverChanged = onHoverChanged
    }

    private var rowBackground: Color {
        if confirming { return Color.orange.opacity(0.12) }
        if isSelected { return Color.accentColor.opacity(0.22) }
        if hovering { return Color.secondary.opacity(0.1) }
        if isHighlighted { return Color.accentColor.opacity(0.14) }
        return .clear
    }

    var body: some View {
        HStack(spacing: 8) {
            // .onTapGesture (not Button) so a focused TextField in the same
            // popover can't eat the first click as "end editing".
            HStack(spacing: 8) {
                Circle()
                    .fill(isActive ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
                Text(label).font(.callout).lineLimit(1)
                Spacer()
                if !confirming {
                    Text(total > 0 ? total.hm : "—")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .opacity(isArchived ? 0.55 : 1)
            .onTapGesture { onTap() }

            if let onArchiveToggle {
                if confirming {
                    Button {
                        onArchiveToggle()
                        confirming = false
                    } label: {
                        Text(isArchived ? "Unarchive" : "Archive")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.18))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)

                    Button { confirming = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else if hovering {
                    Button { confirming = true } label: {
                        Image(systemName: isArchived ? "tray.and.arrow.up" : "archivebox")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isArchived ? "Unarchive this label" : "Archive this label")
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .onHover { h in
            hovering = h
            if !h { confirming = false }
            onHoverChanged?(h ? label : nil)
        }
    }
}
