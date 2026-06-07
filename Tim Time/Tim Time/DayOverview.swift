import SwiftUI

/// Day's at-a-glance header: total time + score, two-line metrics, timeline.
/// Shared by the menu popover and the floating "what are you working on?" prompt.
struct DayOverview: View {
    @ObservedObject var tracker: Tracker
    /// Day being summarized. The prompt always passes today; the menu may pass
    /// a historical day via its day-switcher.
    let date: Date
    /// When non-nil, segments with this label render green in the timeline —
    /// driven by hover on a label row in the parent picker.
    var highlightedLabel: String? = nil

    private var isToday: Bool { Calendar.current.isDateInToday(date) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(tracker.dayTotal(for: date).hms)
                    .font(.system(.title, design: .monospaced))
                Spacer()
                scoreBadge(tracker.dailyScore(for: date))
            }
            let lines = metricsLines
            VStack(alignment: .leading, spacing: 0) {
                Text(lines.top)
                if !lines.bottom.isEmpty { Text(lines.bottom) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            let window = timelineWindow
            DayTimelineView(
                entries: tracker.entries,
                windowStart: window.start,
                windowEnd: window.end,
                runningStart: isToday ? tracker.runningStart : nil,
                runningLabel: isToday ? tracker.currentLabel : "",
                now: tracker.tickNow,
                highlightedLabel: highlightedLabel
            )
        }
    }

    @ViewBuilder
    private func scoreBadge(_ score: DailyScore) -> some View {
        VStack(alignment: .trailing, spacing: -2) {
            Text("\(score.total)")
                .font(.system(.title2, design: .monospaced).weight(.semibold))
                .foregroundStyle(score.total >= 0 ? Color.primary : Color.red)
            Text("score")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .help(scoreBreakdown(score))
    }

    private func scoreBreakdown(_ s: DailyScore) -> String {
        var parts: [String] = []
        if s.focusPoints > 0    { parts.append("+\(s.focusPoints) focus") }
        if s.deepBonus > 0      { parts.append("+\(s.deepBonus) deep blocks (≥50m)") }
        if s.ultradianBonus > 0 { parts.append("+\(s.ultradianBonus) ultradian (≥75m)") }
        if s.breakBonus > 0     { parts.append("+\(s.breakBonus) break cadence") }
        if s.switchPenalty < 0  { parts.append("\(s.switchPenalty) thrash") }
        return parts.isEmpty ? "Nothing scored yet today" : parts.joined(separator: " · ")
    }

    private var metricsLines: (top: String, bottom: String) {
        let switches = tracker.switchCount(for: date)
        let longest = tracker.longestFocus(for: date)
        let breath = tracker.breathStats(for: date)

        var top: [String] = []
        top.append("\(switches) " + (switches == 1 ? "switch" : "switches"))
        if longest > 0 { top.append("longest \(longest.hm)") }

        var bottom: [String] = []
        if breath.total > 0 { bottom.append("\(breath.done)/\(breath.total) breaths") }
        if isToday, let since = tracker.timeSinceLastBreak {
            bottom.append("\(since.hm) since break")
        }
        return (top.joined(separator: " · "), bottom.joined(separator: " · "))
    }

    private var timelineWindow: (start: Date, end: Date) {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? date
        return (start, end)
    }
}
