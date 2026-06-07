import SwiftUI

/// Horizontal strip showing one time window: colored block = on a work label,
/// gray background = untracked / on a break (breaks aren't stored — they read
/// identically to any other untracked gap).
///
/// Hovering a work segment shows its start–end times and time-on-task as a
/// two-line caption below the strip. Hovering a gap shows nothing.
///
/// The window is caller-defined — Today uses rolling now-24h to now; past days
/// use that day's 00:00 to next 00:00. The live running segment is only drawn
/// when `runningStart` is non-nil (i.e., on Today while a task is active);
/// its end timestamp is the window's `end` (= current tick on Today).
struct DayTimelineView: View {
    let entries: [TimeEntry]
    let windowStart: Date
    let windowEnd: Date
    let runningStart: Date?
    let runningLabel: String
    /// Clamps the running-segment drawing/hover so it doesn't extend past
    /// current time when `windowEnd` is in the future (Today = full 24h strip).
    let now: Date
    /// Segments with this label render green — used to mirror a label-row
    /// hover from the picker into the timeline.
    var highlightedLabel: String? = nil

    @State private var hoverInfo: HoverInfo?

    private struct HoverInfo: Equatable {
        let label: String
        let start: Date
        let end: Date
        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                Canvas { context, size in
                    drawTimeline(context: context, size: size)
                }
                .onContinuousHover { phase in
                    handleHover(phase: phase, width: geo.size.width)
                }
            }
            .frame(height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 3))

            // Single-row caption: label · duration left, start–end right.
            // Kept opacity-hidden (rather than collapsed) when not hovering so
            // the popover doesn't reflow on every cursor move.
            HStack {
                Text(hoverInfo.map { "\($0.label) · \($0.duration.hm)" } ?? " ")
                Spacer(minLength: 8)
                Text(hoverInfo.map { formatTimeRange($0.start, $0.end) } ?? " ")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .opacity(hoverInfo == nil ? 0 : 1)
        }
    }

    private func formatTimeRange(_ start: Date, _ end: Date) -> String {
        let s = start.formatted(date: .omitted, time: .shortened)
        let e = end.formatted(date: .omitted, time: .shortened)
        return "\(s) – \(e)"
    }

    private func drawTimeline(context: GraphicsContext, size: CGSize) {
        let totalSeconds = windowEnd.timeIntervalSince(windowStart)
        guard totalSeconds > 0 else { return }

        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(Color.secondary.opacity(0.15))
        )

        func draw(_ start: Date, _ end: Date, highlighted: Bool) {
            let s = max(start, windowStart)
            let e = min(end, windowEnd)
            guard s < e else { return }
            let xs = (s.timeIntervalSince(windowStart) / totalSeconds) * size.width
            let xe = (e.timeIntervalSince(windowStart) / totalSeconds) * size.width
            let rect = CGRect(x: xs, y: 0, width: max(xe - xs, 1), height: size.height)
            let color = highlighted ? Color.green : Color.accentColor
            context.fill(Path(rect), with: .color(color.opacity(0.9)))
        }

        // Highlight: either the segment under the cursor, or any segment whose
        // label matches a label-row hover from the parent picker.
        let hoveredStart = hoverInfo?.start
        for entry in entries {
            let h = entry.start == hoveredStart || entry.label == highlightedLabel
            draw(entry.start, entry.end, highlighted: h)
        }
        if let rs = runningStart {
            let h = rs == hoveredStart || runningLabel == highlightedLabel
            draw(rs, min(now, windowEnd), highlighted: h)
        }
    }

    private func handleHover(phase: HoverPhase, width: CGFloat) {
        switch phase {
        case .active(let location):
            guard width > 0 else { return }
            let frac = max(0, min(1, location.x / width))
            let totalSeconds = windowEnd.timeIntervalSince(windowStart)
            let when = windowStart.addingTimeInterval(totalSeconds * frac)
            hoverInfo = entryAt(when)
        case .ended:
            hoverInfo = nil
        }
    }

    /// Find the entry covering `time`, or the live entry if `time` falls in its
    /// window. Returns nil over untracked gaps, which suppresses the caption.
    private func entryAt(_ time: Date) -> HoverInfo? {
        for entry in entries {
            if entry.start <= time && time < entry.end {
                return HoverInfo(label: entry.label, start: entry.start, end: entry.end)
            }
        }
        if let rs = runningStart, rs <= time, time <= now {
            return HoverInfo(label: runningLabel, start: rs, end: now)
        }
        return nil
    }
}
