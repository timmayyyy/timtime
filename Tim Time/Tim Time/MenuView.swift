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
    /// Same idea for the month view. nil ⇒ current month.
    @State private var selectedMonthAnchor: Date?
    /// Shift-click picks (ordered). Any count: 1 ⇒ rename/color, 2 ⇒ also merge,
    /// 3+ ⇒ color many at once.
    @State private var selection: [String] = []
    /// Which of the three time scopes the popover is showing.
    @State private var viewMode: ViewMode = .day
    /// When true, the whole popover shows the Name Colors editor instead.
    @State private var showColorManager = false
    /// Color swatch currently hovered in the selection bar; its name (if any) is
    /// shown inline so a named color is identifiable without opening Manage.
    @State private var hoveredSwatchID: UUID?

    private enum ViewMode: Equatable { case day, week, month }
    /// Label currently hovered in the picker — DayOverview renders matching
    /// timeline segments in green.
    @State private var hoveredLabel: String?
    /// Same idea for the weekly view: hovering a bar lights up its slots in
    /// the week timeline above.
    @State private var hoveredWeekLabel: String?
    /// Varied copy for the prominent (overdue) break card, picked once per menu
    /// open so each nudge reads as a different attempt.
    @State private var breakPrompt = BreakPrompt.random()
    @FocusState private var inputFocused: Bool

    private var isToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    /// 80% of the current screen's usable height — the ceiling for the whole
    /// popover. The scrollable label lists cap themselves to this minus their
    /// surrounding chrome so the panel never grows past it (the floating panel
    /// has no AppKit height clamp of its own).
    private var maxPanelHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 900) * 0.8
    }

    /// Height cap for the day breakdown scroll region. Reserves room for the
    /// header, input, break card, and footer so the total stays under 80%.
    private var dayListMaxHeight: CGFloat {
        max(200, maxPanelHeight - 470)
    }

    /// Height cap for the weekly bar scroll region.
    private var weekListMaxHeight: CGFloat {
        max(180, maxPanelHeight - 340)
    }

    /// Height cap for the month's per-day rows scroll region.
    private var monthListMaxHeight: CGFloat {
        max(200, maxPanelHeight - 300)
    }

    /// The day's label list, filtered by what the user has typed so far.
    /// Includes archived labels only when "Show archived" is on.
    private func filteredBreakdown() -> [LabelTotal] {
        let breakdown = tracker.allLabelsBreakdown(for: selectedDate, includeArchived: showArchived)
        let q = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return breakdown }
        return breakdown.filter { $0.label.lowercased().contains(q) }
    }

    private var panelWidth: CGFloat {
        if showColorManager { return 360 }
        switch viewMode {
        case .day: return 340
        case .week: return 400
        case .month: return 400
        }
    }

    var body: some View {
        Group {
            if showColorManager {
                manageColorsView
            } else {
                switch viewMode {
                case .day: todayView
                case .week: weeklyView
                case .month: monthView
                }
            }
        }
        .panelContainer(width: panelWidth, onSizeChange: onSizeChange)
        .animation(.easeInOut(duration: 0.22), value: viewMode)
        .animation(.easeInOut(duration: 0.22), value: showColorManager)
        .onAppear {
            selectedDate = Date()
            // Always start in the day view on open — last session's drill-in
            // isn't useful when reopening.
            viewMode = .day
            showColorManager = false
            resetSelection()
            selectedWeekAnchor = nil
            selectedMonthAnchor = nil
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

                    // Pure day-forward nav (greyed on today). The break action
                    // now lives in a fixed spot at the bottom, not up here.
                    Image(systemName: "chevron.right")
                        .font(.body.weight(.medium))
                        .frame(width: 36, height: 28)
                        .contentShape(Rectangle())
                        .opacity(isToday ? 0.25 : 1)
                        .onTapGesture { if !isToday { shiftDay(1) } }
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

            // Label list (filtered by what's been typed). Scrolls internally
            // once it would push the popover past 80% of the screen; the input,
            // selection bar, break card, and footer stay pinned.
            let breakdown = filteredBreakdown()
            if !breakdown.isEmpty {
                ScrollView {
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
                        highlightedLabel: input.isEmpty ? nil : breakdown.first?.label,
                        colorProvider: { tracker.color(for: $0) }
                    )
                    .padding(.trailing, 2)
                }
                .frame(maxHeight: dayListMaxHeight)

                if !selection.isEmpty {
                    selectionBar
                }
            }

            // Take a break — pinned here so there's always one consistent place
            // to step away, independent of the timed check-in nudges. Uses the
            // shared BreakButton, so it escalates to the prominent card on the
            // same rule as the check-in prompt (Tracker.isBreakOverdue).
            if isToday {
                BreakButton(
                    overdue: tracker.isBreakOverdue,
                    timeSinceLastBreak: tracker.timeSinceLastBreak,
                    prompt: breakPrompt
                ) {
                    onDismiss()
                    DispatchQueue.main.async { tracker.takeQuickBreak() }
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
                    viewMode = .week
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
                    highlightedLabel: hoveredWeekLabel,
                    colorFor: { tracker.color(for: $0) }
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
                let weekEnd = Calendar.current.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
                ScrollView {
                    weeklyBarList(weekly)
                        .padding(.trailing, 2)
                }
                .frame(maxHeight: weekListMaxHeight)
                // Pinned below the scrolling bars, so the by-color roll-up is
                // always visible at the bottom (same as the month view).
                colorTotalsSection(tracker.colorTotals(in: weekStart..<weekEnd))
            }

            Divider()
            HStack(spacing: 8) {
                Button {
                    selectedWeekAnchor = nil
                    selectedDate = Date()
                    viewMode = .day
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                        Text("Today")
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    viewMode = .month
                } label: {
                    HStack(spacing: 2) {
                        Text("Month")
                        Image(systemName: "chevron.right")
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Month view

    @ViewBuilder
    private var monthView: some View {
        let monthStart = currentDisplayedMonthStart()
        let isCurrentMonth = Calendar.current.isDate(
            monthStart, equalTo: currentMonthStart(), toGranularity: .month
        )
        let monthEnd = Calendar.current.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
        let colorTotals = tracker.colorTotals(in: monthStart..<monthEnd)
        let monthTotal = colorTotals.reduce(0.0) { $0 + $1.total }

        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.medium))
                        .frame(width: 36, height: 28)
                        .contentShape(Rectangle())
                        .onTapGesture { shiftMonth(-1) }

                    Spacer()
                    Text(monthTitle(monthStart: monthStart))
                        .font(.callout).bold()
                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.body.weight(.medium))
                        .frame(width: 36, height: 28)
                        .contentShape(Rectangle())
                        .opacity(isCurrentMonth ? 0.25 : 1)
                        .onTapGesture { if !isCurrentMonth { shiftMonth(1) } }
                }

                Text(monthTotal.hms)
                    .font(.system(.title, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(WindowDragArea())

            if monthTotal == 0 {
                Text("No time logged this month.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    MonthChartView(tracker: tracker, monthStart: monthStart, monthEnd: monthEnd)
                        .padding(.trailing, 2)
                }
                .frame(maxHeight: monthListMaxHeight)
                // Pinned below the scrolling day rows.
                colorTotalsSection(colorTotals)
            }

            Divider()
            HStack(spacing: 8) {
                Button {
                    viewMode = .week
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                        Text("Week")
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    selectedMonthAnchor = nil
                    selectedDate = Date()
                    viewMode = .day
                } label: {
                    Text("Today")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func shiftMonth(_ delta: Int) {
        let cal = Calendar.current
        let anchor = currentDisplayedMonthStart()
        guard let next = cal.date(byAdding: .month, value: delta, to: anchor) else { return }
        if next > currentMonthStart() {
            selectedMonthAnchor = nil
        } else {
            selectedMonthAnchor = next
        }
    }

    private func currentDisplayedMonthStart() -> Date {
        if let anchor = selectedMonthAnchor {
            return monthStart(of: anchor)
        }
        return currentMonthStart()
    }

    private func currentMonthStart() -> Date { monthStart(of: Date()) }

    private func monthStart(of date: Date) -> Date {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: date))
            ?? cal.startOfDay(for: date)
    }

    private func monthTitle(monthStart: Date) -> String {
        monthStart.formatted(.dateTime.month(.wide).year())
    }

    // MARK: - Manage colors

    @ViewBuilder
    private var manageColorsView: some View {
        ManageColorsView(tracker: tracker) { showColorManager = false }
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

    // MARK: - Selection action bar

    /// Shown whenever one or more labels are shift-selected. Adapts to the count:
    /// 1 ⇒ rename + color, 2 ⇒ merge + color, 3+ ⇒ color many at once.
    @ViewBuilder
    private var selectionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            colorSwatchRow
            if selection.count >= 2 {
                mergeRow
            }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Name shown for the hovered swatch (nil if none / unnamed).
    private var hoveredSwatchLabel: String? {
        guard let id = hoveredSwatchID,
              let name = tracker.colorCategories.first(where: { $0.id == id })?.name,
              !name.isEmpty else { return nil }
        return name
    }

    @ViewBuilder
    private var colorSwatchRow: some View {
        HStack(spacing: 6) {
            Text("Color")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(tracker.colorCategories) { category in
                Button {
                    tracker.setColor(category.id, for: selection)
                    resetSelection()
                } label: {
                    Circle()
                        .fill(category.color)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .onHover { h in
                    if h { hoveredSwatchID = category.id }
                    else if hoveredSwatchID == category.id { hoveredSwatchID = nil }
                }
            }
            // Hovered color's name, inline so it doesn't shift the swatches.
            if let name = hoveredSwatchLabel {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Manage…") { showColorManager = true }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
        }
    }

    /// Merge every selected label into one. With two selected this offers both
    /// directions; with three or more, pick which selected label they all fold
    /// into. Scrolls horizontally so long label names don't clip.
    @ViewBuilder
    private var mergeRow: some View {
        HStack(spacing: 6) {
            Text(selection.count == 2 ? "Merge" : "Merge into")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(selection, id: \.self) { target in
                        Button {
                            mergeSelection(into: target)
                        } label: {
                            Text(mergeButtonLabel(target: target))
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    /// For two labels, show the directional "other → target"; for more, just the
    /// target name (everything else folds into it).
    private func mergeButtonLabel(target: String) -> String {
        if selection.count == 2, let other = selection.first(where: { $0 != target }) {
            return "\(other) → \(target)"
        }
        return target
    }

    private func mergeSelection(into target: String) {
        for label in selection where label != target {
            tracker.mergeLabels(from: label, into: target)
        }
        resetSelection()
    }

    private func resetSelection() {
        selection.removeAll()
        hoveredSwatchID = nil
    }

    // MARK: - By-color rollup

    /// Shared "By color" section (weekly + monthly). Only rendered when two or
    /// more colors are actually in use, so a single-color week stays uncluttered.
    private func colorTotalsSection(_ totals: [ColorTotal]) -> some View {
        let grandTotal = totals.reduce(0.0) { $0 + $1.total }
        return Group {
            if totals.count >= 2 {
                Divider()
                Text("By color")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(totals) { ct in
                        HStack(spacing: 6) {
                            Circle().fill(ct.category.color).frame(width: 9, height: 9)
                            Text(ct.category.name).font(.callout)
                            Spacer()
                            Text(percentString(ct.total, of: grandTotal))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                            Text(ct.total.hm)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 62, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private func percentString(_ value: TimeInterval, of total: TimeInterval) -> String {
        guard total > 0 else { return "" }
        return "\(Int((value / total * 100).rounded()))%"
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
            // Toggle into the multi-select set. No cap — you can color many at
            // once; merge just only offers itself when exactly two are picked.
            if let i = selection.firstIndex(of: label) {
                selection.remove(at: i)
            } else {
                selection.append(label)
            }
            return
        }
        resetSelection()
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
        let dimMode = hoveredWeekLabel != nil
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                let focused = hoveredWeekLabel == item.label
                let barColor = tracker.color(for: item.label)
                let barOpacity: Double = dimMode ? (focused ? 1.0 : 0.28) : 0.85
                VStack(alignment: .leading, spacing: 2) {
                    // No dot — the bar below is already this label's color.
                    Text(item.label).font(.callout)
                    HStack(spacing: 6) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Color.chartTrack
                                barColor
                                    .opacity(barOpacity)
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

