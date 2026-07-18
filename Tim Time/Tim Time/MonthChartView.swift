import SwiftUI

/// Compact per-day timeline for a calendar month — the weekly timeline idiom
/// scaled down. Each row is one day as a 24-hour strip, with work segments drawn
/// at their actual time of day and colored by category. Rows are stacked with no
/// gap so the month reads as one dense block. Hover a row for its date + total.
struct MonthChartView: View {
    @ObservedObject var tracker: Tracker
    /// First day of the displayed month (00:00 local).
    let monthStart: Date
    /// First day of the next month — the half-open upper bound.
    let monthEnd: Date

    private let stripHeight: CGFloat = 5

    private var dayCount: Int {
        Calendar.current.dateComponents([.day], from: monthStart, to: monthEnd).day ?? 30
    }

    var body: some View {
        let cal = Calendar.current
        let now = Date()
        VStack(spacing: 0) {
            ForEach(0..<dayCount, id: \.self) { offset in
                let dayStart = cal.date(byAdding: .day, value: offset, to: monthStart) ?? monthStart
                let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
                Canvas { ctx, size in
                    drawDay(ctx: ctx, size: size, dayStart: dayStart, dayEnd: dayEnd, now: now)
                }
                .frame(height: stripHeight)
                .help(helpText(dayStart: dayStart))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func drawDay(ctx: GraphicsContext, size: CGSize, dayStart: Date, dayEnd: Date, now: Date) {
        let totalSeconds = dayEnd.timeIntervalSince(dayStart)
        guard totalSeconds > 0 else { return }

        ctx.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(Color.chartTrack)
        )

        func draw(_ label: String, _ start: Date, _ end: Date) {
            let s = max(start, dayStart)
            let e = min(end, dayEnd, now)
            guard s < e else { return }
            let xs = (s.timeIntervalSince(dayStart) / totalSeconds) * size.width
            let xe = (e.timeIntervalSince(dayStart) / totalSeconds) * size.width
            let rect = CGRect(x: xs, y: 0, width: max(xe - xs, 1), height: size.height)
            ctx.fill(Path(rect), with: .color(tracker.color(for: label).opacity(0.9)))
        }

        for entry in tracker.entries {
            draw(entry.label, entry.start, entry.end)
        }
        if let rs = tracker.runningStart, !tracker.currentLabel.isEmpty {
            draw(tracker.currentLabel, rs, now)
        }
    }

    private func helpText(dayStart: Date) -> String {
        let d = dayStart.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let total = tracker.dayTotal(for: dayStart)
        return total > 0 ? "\(d) · \(total.hm)" : "\(d) · —"
    }
}
