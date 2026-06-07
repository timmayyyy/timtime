import SwiftUI
import AppKit

struct MenuView: View {
    @ObservedObject var tracker: Tracker
    /// Closes the AppKit-managed popover. Wired by AppDelegate.
    let onDismiss: () -> Void
    /// True when the popover was opened by the wake-from-sleep handler; the
    /// header briefly shows "Welcome back" before fading to the normal title.
    let welcomeBack: Bool
    /// Fired by a GeometryReader-based PreferenceKey whenever the SwiftUI
    /// content's intrinsic size changes — AppDelegate uses it to keep the
    /// floating-panel sized + pinned to the screen-right edge.
    let onSizeChange: (CGSize) -> Void
    @AppStorage("showArchived") private var showArchived = false
    @State private var input = ""
    /// Drives the brief "Welcome back" header swap on wake-from-sleep opens.
    @State private var welcomeVisible = false
    @State private var selectedDate = Date()
    /// Anchor date inside the currently-shown week for the weekly view. nil ⇒
    /// "this week" (always tracks `Date()`); otherwise a Date inside a past week.
    @State private var selectedWeekAnchor: Date?
    @State private var selection: [String] = []   // shift-click picks (ordered, max 2)
    @State private var showWeekly = false
    /// Label currently hovered in the picker — DayOverview renders matching
    /// timeline segments in green.
    @State private var hoveredLabel: String?
    /// Same idea for the weekly view: hovering a bar lights up its slots in
    /// the week timeline above.
    @State private var hoveredWeekLabel: String?
    @FocusState private var inputFocused: Bool

    private var isToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    /// The day's label list, filtered by what the user has typed so far.
    /// Includes archived labels only when "Show archived" is on.
    private func filteredBreakdown() -> [LabelTotal] {
        let breakdown = tracker.allLabelsBreakdown(for: selectedDate, includeArchived: showArchived)
        let q = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return breakdown }
        return breakdown.filter { $0.label.lowercased().contains(q) }
    }

    var body: some View {
        Group {
            if showWeekly {
                weeklyView
            } else {
                todayView
            }
        }
        .panelContainer(width: showWeekly ? 400 : 340, onSizeChange: onSizeChange)
        .animation(.easeInOut(duration: 0.22), value: showWeekly)
        .onAppear {
            selectedDate = Date()
            // Always start in the day view on open — last session's drill-in
            // isn't useful when reopening.
            showWeekly = false
            selectedWeekAnchor = nil
            input = ""
            DispatchQueue.main.async { inputFocused = true }
            if welcomeBack {
                welcomeVisible = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(1800))
                    withAnimation(.easeInOut(duration: 0.35)) {
                        welcomeVisible = false
                    }
                }
            }
        }
    }

    // MARK: - Today view

    @ViewBuilder
    private var todayView: some View {
        VStack(alignment: .leading, spacing: 10) {

            // Whole top section (chevron header + DayOverview) is the drag
            // zone. Interactive bits (chevrons, Break?, score tooltip, timeline
            // hover) keep working because SwiftUI tap/hover gestures take
            // priority over the un-handled mouseDown that falls to the drag.
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 0) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.medium))
                        .frame(width: 36, height: 28)
                        .contentShape(Rectangle())
                        .onTapGesture { shiftDay(-1) }

                    Spacer()
                    Text(welcomeVisible ? "Welcome back" : dayLabel)
                        .font(.callout).bold()
                        .id(welcomeVisible ? "welcome" : "day")
                        .transition(.opacity)
                    Spacer()

                    if isToday && tracker.isRunning {
                        Text("Break?")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Color.blue)
                            .frame(height: 28)
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onDismiss()
                                DispatchQueue.main.async {
                                    tracker.takeQuickBreak()
                                }
                            }
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.body.weight(.medium))
                            .frame(width: 36, height: 28)
                            .contentShape(Rectangle())
                            .opacity(isToday ? 0.25 : 1)
                            .onTapGesture { if !isToday { shiftDay(1) } }
                    }
                }

                DayOverview(tracker: tracker, date: selectedDate, highlightedLabel: hoveredLabel)
            }
            .background(WindowDragArea())

            Divider()

            // Quick add / switch — always-focused. Typing routes here, Enter
            // picks the top filtered row (or creates the typed label if no
            // matches). No visible focus state since it's permanently live.
            if isToday {
                TextField("Add or switch to…", text: $input)
                    .focused($inputFocused)
                    .onSubmit(submit)
                    .filterFieldChrome()
            }

            // Label list (filtered by what's been typed)
            let breakdown = filteredBreakdown()
            if !breakdown.isEmpty {
                BucketedLabelList(
                    groups: pickerGroups(from: breakdown),
                    onTap: { handleTap($0) },
                    onArchiveToggle: { label in
                        if tracker.isArchived(label) {
                            tracker.unarchiveLabel(label)
                        } else {
                            tracker.archiveLabel(label)
                        }
                        selection.removeAll { $0 == label }
                    },
                    onHoverChanged: { hoveredLabel = $0 },
                    highlightedLabel: input.isEmpty ? nil : breakdown.first?.label
                )

                if selection.count == 2 {
                    mergeBar(a: selection[0], b: selection[1])
                }
            }

            // Footer
            Divider()
            HStack {
                if tracker.isRunning && isToday {
                    Button("Stop", action: tracker.stop)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showWeekly = true
                } label: {
                    HStack(spacing: 2) {
                        Text("Week")
                        Image(systemName: "chevron.right")
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Weekly view

    @ViewBuilder
    private var weeklyView: some View {
        let weekStart = currentDisplayedWeekStart()
        let isCurrentWeek = Calendar.current.isDate(
            weekStart, equalTo: currentWeekStart(), toGranularity: .day
        )
        let weekly = tracker.weeklyBreakdown(weekStart: weekStart)
        let weekTotal = weekly.reduce(0.0) { $0 + $1.total }

        VStack(alignment: .leading, spacing: 8) {
            // Drag zone covers everything above the interactive bar list —
            // header, total + score, and the timeline strips (which only have
            // hover, no taps, so dragging from them is fine).
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.medium))
                        .frame(width: 36, height: 28)
                        .contentShape(Rectangle())
                        .onTapGesture { shiftWeek(-1) }

                    Spacer()
                    Text(weekTitle(weekStart: weekStart, isCurrent: isCurrentWeek))
                        .font(.callout).bold()
                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.body.weight(.medium))
                        .frame(width: 36, height: 28)
                        .contentShape(Rectangle())
                        .opacity(isCurrentWeek ? 0.25 : 1)
                        .onTapGesture { if !isCurrentWeek { shiftWeek(1) } }
                }

                VStack(spacing: 2) {
                    Text(weekTotal.hms)
                        .font(.system(.title, design: .monospaced))
                    weeklyScoreLine(weekStart: weekStart)
                }
                .frame(maxWidth: .infinity, alignment: .center)

                WeekTimelineView(
                    entries: tracker.entries,
                    weekStart: weekStart,
                    runningStart: isCurrentWeek ? tracker.runningStart : nil,
                    runningLabel: isCurrentWeek ? tracker.currentLabel : "",
                    highlightedLabel: hoveredWeekLabel
                )
            }
            .background(WindowDragArea())

            if weekly.isEmpty {
                Text("No time logged this week.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                weeklyBarList(weekly)
            }

            Divider()
            HStack(spacing: 8) {
                Button {
                    selectedWeekAnchor = nil
                    showWeekly = false
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                        Text("Today")
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)

                Spacer()
            }
        }
    }

    private func shiftWeek(_ delta: Int) {
        let cal = Calendar.current
        let anchor = currentDisplayedWeekStart()
        guard let next = cal.date(byAdding: .day, value: delta * 7, to: anchor) else { return }
        // Clamp forward navigation to "this week" — we don't show future weeks.
        if next > currentWeekStart() {
            selectedWeekAnchor = nil
        } else {
            selectedWeekAnchor = next
        }
    }

    private func currentDisplayedWeekStart() -> Date {
        if let anchor = selectedWeekAnchor {
            let cal = Calendar.current
            return cal.date(from: cal.dateComponents(
                [.yearForWeekOfYear, .weekOfYear], from: anchor
            )) ?? anchor
        }
        return currentWeekStart()
    }

    private func weekTitle(weekStart: Date, isCurrent: Bool) -> String {
        if isCurrent { return "This Week" }
        let cal = Calendar.current
        let weekEnd = cal.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        let s = weekStart.formatted(.dateTime.month(.abbreviated).day())
        let e = weekEnd.formatted(.dateTime.month(.abbreviated).day())
        return "\(s) – \(e)"
    }

    /// Start of the current week per the user's calendar (Sunday or Monday
    /// depending on locale).
    private func currentWeekStart() -> Date {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents(
            [.yearForWeekOfYear, .weekOfYear], from: Date()
        )) ?? cal.startOfDay(for: Date())
    }

    // MARK: - Merge bar

    @ViewBuilder
    private func mergeBar(a: String, b: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Merge")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Button {
                    tracker.mergeLabels(from: a, into: b)
                    selection.removeAll()
                } label: {
                    Text("\(a) → \(b)").font(.caption).lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    tracker.mergeLabels(from: b, into: a)
                    selection.removeAll()
                } label: {
                    Text("\(b) → \(a)").font(.caption).lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button("Cancel") { selection.removeAll() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Bucketing

    /// Group the day's breakdown into recency buckets, converting each `LabelTotal`
    /// into a `PickerItem` that the shared `BucketedLabelList` can render directly.
    /// Within-bucket order (active first, then total desc, then alphabetical) is
    /// inherited from `allLabelsBreakdown`'s sort.
    private func pickerGroups(from breakdown: [LabelTotal]) -> [PickerBucket] {
        let recency = Dictionary(
            uniqueKeysWithValues: tracker.labelsByRecency(includeArchived: showArchived)
                .map { ($0.label, $0.lastSeen) }
        )
        let now = Date()
        var bucketed: [LabelBucket: [PickerItem]] = [:]
        for item in breakdown {
            let archived = tracker.isArchived(item.label)
            // Archived labels go to their own bucket regardless of recency.
            let bucket: LabelBucket = archived
                ? .archived
                : .bucket(for: recency[item.label] ?? .distantPast, now: now)
            bucketed[bucket, default: []].append(PickerItem(
                label: item.label,
                total: item.total,
                isActive: tracker.isRunning && tracker.currentLabel == item.label,
                isSelected: selection.contains(item.label),
                isArchived: archived
            ))
        }
        return LabelBucket.allCases.compactMap { bucket in
            guard let items = bucketed[bucket], !items.isEmpty else { return nil }
            return PickerBucket(bucket: bucket, items: items)
        }
    }

    // MARK: - Interaction

    private func handleTap(_ label: String) {
        if NSEvent.modifierFlags.contains(.shift) {
            if let i = selection.firstIndex(of: label) {
                selection.remove(at: i)
            } else {
                selection.append(label)
                if selection.count > 2 { selection.removeFirst() }
            }
            return
        }
        selection.removeAll()
        tracker.start(label)
        selectedDate = Date()
        // Auto-opened popover (wake handler) was asking "what now?" — tapping
        // a label answers it, so dismiss. Manual opens stay put.
        if welcomeBack { onDismiss() }
    }

    // MARK: - Helpers

    private var dayLabel: String {
        if isToday { return "Today" }
        if Calendar.current.isDateInYesterday(selectedDate) { return "Yesterday" }
        return selectedDate.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    /// Hoverable per-label rows for the weekly view. Hovering a row sets
    /// `hoveredWeekLabel`, which lights up the matching segments in the
    /// week timeline above.
    @ViewBuilder
    private func weeklyBarList(_ items: [LabelTotal]) -> some View {
        let maxTotal = items.first?.total ?? 1
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                let hovered = hoveredWeekLabel == item.label
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label).font(.callout)
                    HStack(spacing: 6) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Color.secondary.opacity(0.15)
                                (hovered ? Color.green : Color.accentColor)
                                    .opacity(0.75)
                                    .frame(width: geo.size.width * (item.total / maxTotal))
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                        }
                        .frame(height: 8)

                        Text(item.total.hm)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                .contentShape(Rectangle())
                .onHover { h in hoveredWeekLabel = h ? item.label : nil }
            }
        }
    }

    /// Weekly score = sum of each day's score. Hover lists per-day totals.
    @ViewBuilder
    private func weeklyScoreLine(weekStart: Date) -> some View {
        let cal = Calendar.current
        let dayScores: [(date: Date, score: DailyScore)] = (0..<7).compactMap { offset in
            guard let d = cal.date(byAdding: .day, value: offset, to: weekStart) else { return nil }
            guard cal.startOfDay(for: d) <= cal.startOfDay(for: Date()) else { return nil }
            return (d, tracker.dailyScore(for: d))
        }
        let total = dayScores.reduce(0) { $0 + $1.score.total }
        HStack(spacing: 4) {
            Text("Score")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(total)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(total >= 0 ? Color.primary : Color.red)
        }
        .help(weeklyScoreBreakdown(dayScores))
    }

    private func weeklyScoreBreakdown(_ dayScores: [(date: Date, score: DailyScore)]) -> String {
        dayScores
            .map { "\($0.date.formatted(.dateTime.weekday(.abbreviated))) \($0.score.total)" }
            .joined(separator: " · ")
    }

    private func shiftDay(_ delta: Int) {
        let cal = Calendar.current
        guard let newDate = cal.date(byAdding: .day, value: delta, to: selectedDate) else { return }
        if cal.compare(newDate, to: Date(), toGranularity: .day) != .orderedDescending {
            selectedDate = newDate
        }
    }

    private func submit() {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Pick the top filtered match if there is one (matches the row the
        // user sees highlighted); otherwise start a new label with the typed
        // text. Keep focus so the user can keep typing.
        let target = filteredBreakdown().first?.label ?? trimmed
        tracker.start(target)
        selectedDate = Date()
        input = ""
    }
}

