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
    /// When set (via a label-row hover), that label's segments stay vivid and
    /// the rest dim, so the user can pick one label's time out of the strip.
    var highlightedLabel: String? = nil
    /// Maps a label to its category color. Defaults to accent.
    var colorFor: (String) -> Color = { _ in .accentColor }

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
            with: .color(Color.chartTrack)
        )

        // A label-row hover (highlightedLabel) dims everything but that label so
        // its time stands out. A direct strip hover just brightens the segment
        // under the cursor without dimming the rest.
        let hoveredStart = hoverInfo?.start
        let dimMode = highlightedLabel != nil

        func draw(_ label: String, _ start: Date, _ end: Date, focused: Bool) {
            let s = max(start, windowStart)
            let e = min(end, windowEnd)
            guard s < e else { return }
            let xs = (s.timeIntervalSince(windowStart) / totalSeconds) * size.width
            let xe = (e.timeIntervalSince(windowStart) / totalSeconds) * size.width
            let rect = CGRect(x: xs, y: 0, width: max(xe - xs, 1), height: size.height)
            let opacity: Double = dimMode ? (focused ? 0.95 : 0.22) : (focused ? 1.0 : 0.9)
            context.fill(Path(rect), with: .color(colorFor(label).opacity(opacity)))
        }

        for entry in entries {
            let f = entry.start == hoveredStart || entry.label == highlightedLabel
            draw(entry.label, entry.start, entry.end, focused: f)
        }
        if let rs = runningStart {
            let f = rs == hoveredStart || runningLabel == highlightedLabel
            draw(runningLabel, rs, min(now, windowEnd), focused: f)
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
