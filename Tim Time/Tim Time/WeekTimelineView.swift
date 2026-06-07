import SwiftUI

/// 7-row week timeline. Each row = one day of the displayed week, with a 24-hour
/// strip of work segments and a per-day total to the right.
///
/// Hovering a segment highlights it green so its boundaries are visually clear,
/// and surfaces the entry's start–end / label / duration in a single shared
/// caption below the rows. Hovering an empty gap shows nothing.
struct WeekTimelineView: View {
    let entries: [TimeEntry]
    let weekStart: Date
    let runningStart: Date?
    let runningLabel: String
    /// Segments with this label paint green — mirrors a hover on a row in the
    /// weekly bar list, same idiom as DayTimelineView's `highlightedLabel`.
    var highlightedLabel: String? = nil

    @State private var hover: HoverState?

    private struct HoverState: Equatable {
        let dayIndex: Int
        let label: String
        let start: Date
        let end: Date
        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    private let stripHeight: CGFloat = 20
    private let rowSpacing: CGFloat = 3
    private let dayLabelWidth: CGFloat = 28
    private let totalLabelWidth: CGFloat = 52

    var body: some View {
        let cal = Calendar.current
        let now = Date()
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: rowSpacing) {
                ForEach(0..<7, id: \.self) { offset in
                    let dayStart = cal.date(byAdding: .day, value: offset, to: weekStart) ?? weekStart
                    let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
                    row(offset: offset, dayStart: dayStart, dayEnd: dayEnd, now: now)
                }
            }

            // Single-row caption: label · duration left, day · start–end right.
            // Same idiom as the daily timeline; opacity-hidden when not hovering
            // so the popover doesn't reflow on cursor movement.
            HStack {
                Text(hover.map { "\($0.label) · \($0.duration.hm)" } ?? " ")
                Spacer(minLength: 8)
                Text(hover.map { "\(weekdayName(at: $0.dayIndex)) · \(formatTimeRange($0.start, $0.end))" } ?? " ")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .opacity(hover == nil ? 0 : 1)
        }
    }

    @ViewBuilder
    private func row(offset: Int, dayStart: Date, dayEnd: Date, now: Date) -> some View {
        HStack(spacing: 6) {
            Text(dayStart.formatted(.dateTime.weekday(.abbreviated)))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: dayLabelWidth, alignment: .leading)

            GeometryReader { geo in
                Canvas { ctx, size in
                    drawDay(ctx: ctx, size: size, offset: offset,
                            dayStart: dayStart, dayEnd: dayEnd, now: now)
                }
                .onContinuousHover { phase in
                    handleHover(phase: phase, offset: offset,
                                dayStart: dayStart, dayEnd: dayEnd,
                                width: geo.size.width, now: now)
                }
            }
            .frame(height: stripHeight)
            .clipShape(RoundedRectangle(cornerRadius: 3))

            let total = dayTotal(dayStart: dayStart, dayEnd: dayEnd, now: now)
            Text(total > 0 ? total.hm : "—")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: totalLabelWidth, alignment: .trailing)
        }
    }

    private func drawDay(ctx: GraphicsContext, size: CGSize, offset: Int,
                         dayStart: Date, dayEnd: Date, now: Date) {
        let totalSeconds = dayEnd.timeIntervalSince(dayStart)
        guard totalSeconds > 0 else { return }

        ctx.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(Color.secondary.opacity(0.15))
        )

        func draw(_ start: Date, _ end: Date, highlighted: Bool) {
            let s = max(start, dayStart)
            let e = min(end, dayEnd, now)
            guard s < e else { return }
            let xs = (s.timeIntervalSince(dayStart) / totalSeconds) * size.width
            let xe = (e.timeIntervalSince(dayStart) / totalSeconds) * size.width
            let rect = CGRect(x: xs, y: 0, width: max(xe - xs, 1), height: size.height)
            let color = highlighted ? Color.green : Color.accentColor
            ctx.fill(Path(rect), with: .color(color.opacity(0.9)))
        }

        // Identify the hovered entry by its start date — entries don't share starts.
        let hoveredStart: Date? = {
            guard let h = hover, h.dayIndex == offset else { return nil }
            return h.start
        }()

        for entry in entries {
            let h = entry.start == hoveredStart || entry.label == highlightedLabel
            draw(entry.start, entry.end, highlighted: h)
        }
        if let rs = runningStart, !runningLabel.isEmpty {
            let h = rs == hoveredStart || runningLabel == highlightedLabel
            draw(rs, now, highlighted: h)
        }
    }

    private func handleHover(phase: HoverPhase, offset: Int,
                             dayStart: Date, dayEnd: Date,
                             width: CGFloat, now: Date) {
        switch phase {
        case .active(let location):
            guard width > 0 else { return }
            let frac = max(0, min(1, location.x / width))
            let totalSeconds = dayEnd.timeIntervalSince(dayStart)
            let when = dayStart.addingTimeInterval(totalSeconds * frac)
            hover = entryAt(when, offset: offset, now: now)
        case .ended:
            hover = nil
        }
    }

    /// Return the entry covering `time` (with full original start–end range, not
    /// clipped to day boundaries — we want hover to show the whole task).
    private func entryAt(_ time: Date, offset: Int, now: Date) -> HoverState? {
        for entry in entries where entry.start <= time && time < entry.end {
            return HoverState(
                dayIndex: offset,
                label: entry.label,
                start: entry.start,
                end: entry.end
            )
        }
        if let rs = runningStart, !runningLabel.isEmpty,
           rs <= time, time <= now {
            return HoverState(
                dayIndex: offset,
                label: runningLabel,
                start: rs,
                end: now
            )
        }
        return nil
    }

    private func dayTotal(dayStart: Date, dayEnd: Date, now: Date) -> TimeInterval {
        let cap = min(dayEnd, now)
        var total: TimeInterval = 0
        for entry in entries {
            let s = max(entry.start, dayStart)
            let e = min(entry.end, cap)
            if s < e { total += e.timeIntervalSince(s) }
        }
        if let rs = runningStart, !runningLabel.isEmpty {
            let s = max(rs, dayStart)
            if s < cap { total += cap.timeIntervalSince(s) }
        }
        return total
    }

    private func weekdayName(at offset: Int) -> String {
        let cal = Calendar.current
        let d = cal.date(byAdding: .day, value: offset, to: weekStart) ?? weekStart
        return d.formatted(.dateTime.weekday(.abbreviated))
    }

    private func formatTimeRange(_ start: Date, _ end: Date) -> String {
        let s = start.formatted(date: .omitted, time: .shortened)
        let e = end.formatted(date: .omitted, time: .shortened)
        return "\(s) – \(e)"
    }
}
