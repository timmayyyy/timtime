import Foundation
import Combine
import AppKit

@MainActor
final class Tracker: ObservableObject {
    @Published private(set) var entries: [TimeEntry] = []
    @Published private(set) var breathEvents: [BreathEvent] = []
    @Published private(set) var currentLabel: String = ""
    @Published private(set) var runningStart: Date?
    @Published private(set) var tickNow: Date = Date()
    /// Label names the user has archived. Hidden from picker/breakdown by
    /// default; entries are kept intact so totals & timeline stay accurate.
    @Published private(set) var archivedLabels: Set<String> = []

    private var tickTask: Task<Void, Never>?
    private let storeURL: URL
    private let breathStoreURL: URL
    /// Holds the live entry's label/start/last-checkpoint so a hard kill
    /// (Xcode Stop, force quit, crash) loses at most ~1 min.
    private let runningStoreURL: URL
    private let archivedStoreURL: URL
    private let nudger = Nudger()
    /// Hook for the wake-from-sleep handler — set by AppDelegate so we can
    /// pop the menu open instead of a separate "welcome back" panel.
    var onWakePrompt: (() -> Void)?
    /// Fired whenever `start(_:)` actually starts a new task. Nudger uses
    /// this to anchor its 15/15/45 prompt cycle to real user activity.
    var onTaskStarted: (() -> Void)?

    /// On-disk shape of the running entry. Encoded into `running.json` while a task
    /// is active and removed when the entry closes cleanly.
    private struct RunningState: Codable {
        let label: String
        let start: Date
        let lastCheckpoint: Date
    }
    /// Set on `willSleep`, read on `didWake` to gate the welcome-back prompt
    /// (we suppress it for very short lid bumps).
    private var sleepStart: Date?
    /// Sleeps shorter than this don't count as a break (lid bump, brief screen-off).
    private let sleepBreakThreshold: TimeInterval = 60
    /// Gaps in tracked work this long or longer count as a break for the
    /// re-derived `timeSinceLastBreak`. Shorter gaps are treated as quick label
    /// switches and don't reset the counter.
    private let breakGapThreshold: TimeInterval = 2 * 60

    init() {
        let fm = FileManager.default
        let dir = try! fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
            .appendingPathComponent("TimTime", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storeURL = dir.appendingPathComponent("entries.json")
        self.breathStoreURL = dir.appendingPathComponent("breaths.json")
        self.runningStoreURL = dir.appendingPathComponent("running.json")
        self.archivedStoreURL = dir.appendingPathComponent("archived.json")
        Self.migrateFromContainerIfNeeded(to: dir)
        load()
        // Recover any in-progress entry left behind by a hard kill before we start
        // taking new actions, so the recovered segment lands in the right order.
        restoreRunningIfAny()
        loadBreaths()
        loadArchived()
        nudger.start(tracker: self)
        observeSleep()
        // After the app has settled (and the SMAppService login-item launch isn't
        // racing with the user opening other apps), prompt if nothing is being
        // tracked — covers the "logged in, forgot to click anything" case.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            self?.nudger.promptIfIdle()
        }
    }

    /// One-time copy from the legacy sandboxed container path to the new
    /// non-sandboxed Application Support location. Idempotent: skips any
    /// file already present at the destination. Copies (not moves) so the
    /// original is left behind as a safety net.
    private static func migrateFromContainerIfNeeded(to newDir: URL) {
        let fm = FileManager.default
        let containerDir = URL(fileURLWithPath: NSString(string:
            "~/Library/Containers/AI-Ascend.Tim-Time/Data/Library/Application Support/TimTime"
        ).expandingTildeInPath)
        guard fm.fileExists(atPath: containerDir.path) else { return }
        for file in ["entries.json", "breaths.json", "running.json", "archived.json"] {
            let src = containerDir.appendingPathComponent(file)
            let dst = newDir.appendingPathComponent(file)
            guard fm.fileExists(atPath: src.path),
                  !fm.fileExists(atPath: dst.path) else { continue }
            try? fm.copyItem(at: src, to: dst)
        }
    }

    /// Treat laptop sleep as a break: stop tracking on willSleep, then on didWake
    /// log the sleep window as a Break entry (if it was substantial). This resets
    /// `timeSinceLastBreak` and shows the break in the day breakdown like any other.
    private func observeSleep() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.handleWillSleep()
            }
        }
        nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.handleDidWake()
            }
        }
    }

    private func handleWillSleep() {
        sleepStart = Date()
        // Cancel queued Nudger fires so a stale work/breath prompt can't
        // surface alongside the wake handler's chosen surface.
        nudger.cancelTimers()
        stop()
    }

    /// Sleep ≥ this counts as "fully away" — show the picker on wake instead
    /// of the on-break view. Below this, treat it as a short break and let
    /// the user click Done when ready.
    private let longSleepThreshold: TimeInterval = 10 * 60

    private func handleDidWake() {
        defer { sleepStart = nil }
        // Always restart the periodic timers from wake, even for lid bumps.
        nudger.resetTimers()
        guard let start = sleepStart else { return }
        let duration = Date().timeIntervalSince(start)
        guard duration >= sleepBreakThreshold else { return }

        if duration < longSleepThreshold {
            // Short sleep → show the breath panel with elapsed pre-rolled so
            // it reads "you've been on break for Xm". User clicks Done to resume.
            nudger.showBreath(autoStartAt: start)
        } else {
            // Long sleep → fresh start. Open the menu popover with welcome-back.
            onWakePrompt?()
        }
    }

    var isRunning: Bool { runningStart != nil }

    var elapsed: TimeInterval {
        guard let s = runningStart else { return 0 }
        return tickNow.timeIntervalSince(s)
    }

    // MARK: - Actions

    func start(_ label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if isRunning && currentLabel == trimmed { return }
        closeCurrentEntry()
        currentLabel = trimmed
        runningStart = Date()
        tickNow = Date()
        startTicker()
        save()
        saveRunningCheckpoint()
        onTaskStarted?()
    }

    func stop() {
        closeCurrentEntry()
        currentLabel = ""
        save()
    }

    /// Hide a label from picker/breakdown without deleting any entries. Stops
    /// tracking first if it's the running label.
    func archiveLabel(_ label: String) {
        if isRunning && currentLabel == label {
            closeCurrentEntry()
            currentLabel = ""
            save()
        }
        archivedLabels.insert(label)
        saveArchived()
    }

    func unarchiveLabel(_ label: String) {
        archivedLabels.remove(label)
        saveArchived()
    }

    func isArchived(_ label: String) -> Bool { archivedLabels.contains(label) }

    /// Log a breath reminder response. `done=true` if the user did it, `false` if they skipped.
    func logBreath(done: Bool) {
        breathEvents.insert(BreathEvent(timestamp: Date(), done: done), at: 0)
        saveBreaths()
    }

    /// Seconds since the latest break today (max of: last completed breath
    /// event, or end of an inferred gap ≥ `breakGapThreshold`). nil on a break.
    var timeSinceLastBreak: TimeInterval? {
        let now = Date()
        let dayStart = Calendar.current.startOfDay(for: now)
        let segs = segments(on: now)

        guard let last = segs.last else { return nil }
        // Currently in a long gap (not actively working) → metric not meaningful.
        if now.timeIntervalSince(last.end) > breakGapThreshold { return nil }

        // Source 1: most recent completed breath (catches sub-threshold breaks).
        var breakMarker: Date? = breathEvents
            .filter { $0.done && $0.timestamp >= dayStart }
            .map(\.timestamp)
            .max()

        // Source 2: end of most recent inferred gap ≥ threshold.
        for i in stride(from: segs.count - 1, through: 1, by: -1) {
            let gap = segs[i].start.timeIntervalSince(segs[i - 1].end)
            if gap >= breakGapThreshold {
                let gapEnd = segs[i].start
                breakMarker = breakMarker.map { max($0, gapEnd) } ?? gapEnd
                break
            }
        }

        // No break detected at all — fall back to today's first work moment.
        let reference = breakMarker ?? segs.first?.start
        return reference.map { now.timeIntervalSince($0) }
    }

    /// Quick-break flow — opens the breath panel pre-started so the user goes
    /// straight to the timer + Done.
    func takeQuickBreak() {
        nudger.showBreath(autoStartAt: Date())
    }

    /// (done, total) breath-reminder responses on the given day.
    func breathStats(for date: Date) -> (done: Int, total: Int) {
        let cal = Calendar.current
        let todays = breathEvents.filter { cal.isDate($0.timestamp, inSameDayAs: date) }
        return (todays.filter(\.done).count, todays.count)
    }

    /// Rename every entry with `from` to `into`. If `from` is running, switch the live label without breaking the running segment.
    func mergeLabels(from source: String, into target: String) {
        let trimmedTarget = target.trimmingCharacters(in: .whitespaces)
        guard !trimmedTarget.isEmpty, source != trimmedTarget else { return }
        for i in entries.indices where entries[i].label == source {
            entries[i].label = trimmedTarget
        }
        if isRunning && currentLabel == source {
            currentLabel = trimmedTarget
        }
        save()
    }

    // MARK: - Queries

    /// All work segments overlapping the half-open range, clipped to it, sorted
    /// ascending. Includes the live running entry. Single workhorse the day/week
    /// aggregations build on — keeps the "what counts as time on task in this
    /// window" rule in one place.
    func segments(in range: Range<Date>) -> [DaySegment] {
        let cap = min(range.upperBound, Date())
        var segs: [DaySegment] = entries.compactMap { e in
            let s = max(e.start, range.lowerBound)
            let end = min(e.end, cap)
            return s < end ? DaySegment(label: e.label, start: s, end: end) : nil
        }
        if isRunning, !currentLabel.isEmpty, let rs = runningStart {
            let s = max(rs, range.lowerBound)
            let end = min(Date(), cap)
            if s < end { segs.append(DaySegment(label: currentLabel, start: s, end: end)) }
        }
        segs.sort { $0.start < $1.start }
        return segs
    }

    /// Day-bounded segments (00:00 → next 00:00 local).
    func segments(on date: Date) -> [DaySegment] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? date
        return segments(in: dayStart..<dayEnd)
    }

    /// The label the user was most recently working on — running label if tracking,
    /// else the newest entry.
    var lastWorkedLabel: String? {
        if isRunning, !currentLabel.isEmpty { return currentLabel }
        return entries.first?.label
    }

    /// Every label ever used, with last-seen timestamp, today's total time, and active flag.
    /// Sorted newest first. Archived labels are excluded unless `includeArchived` is true.
    func labelsByRecency(includeArchived: Bool = false) -> [LabelEntry] {
        let cal = Calendar.current
        let now = Date()
        let dayStart = cal.startOfDay(for: now)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? now

        var lastSeen: [String: Date] = [:]
        var todayTotals: [String: TimeInterval] = [:]

        for entry in entries {
            if (lastSeen[entry.label] ?? .distantPast) < entry.end {
                lastSeen[entry.label] = entry.end
            }
            let s = max(entry.start, dayStart)
            let e = min(entry.end, dayEnd)
            if s < e {
                todayTotals[entry.label, default: 0] += e.timeIntervalSince(s)
            }
        }
        if isRunning, !currentLabel.isEmpty, let rs = runningStart {
            lastSeen[currentLabel] = now
            let s = max(rs, dayStart)
            let e = min(now, dayEnd)
            if s < e {
                todayTotals[currentLabel, default: 0] += e.timeIntervalSince(s)
            }
        }

        let active = isRunning ? currentLabel : nil
        return lastSeen
            .compactMap { (label, seen) -> LabelEntry? in
                if !includeArchived && archivedLabels.contains(label) { return nil }
                return LabelEntry(
                    label: label,
                    lastSeen: seen,
                    todayTotal: todayTotals[label] ?? 0,
                    isActive: label == active
                )
            }
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Total time spent on `label` today, including the live segment.
    func todayTotal(for label: String) -> TimeInterval {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: Date())
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return 0 }
        var total: TimeInterval = 0
        for entry in entries where entry.label == label {
            let s = max(entry.start, dayStart)
            let e = min(entry.end, dayEnd)
            if s < e { total += e.timeIntervalSince(s) }
        }
        if isRunning, currentLabel == label, let rs = runningStart {
            let s = max(rs, dayStart)
            let e = min(Date(), dayEnd)
            if s < e { total += e.timeIntervalSince(s) }
        }
        return total
    }

    func dayTotal(for date: Date) -> TimeInterval {
        segments(on: date).reduce(0) { $0 + $1.duration }
    }

    /// Every label ever used, with its total for the given day (0 if not touched that day).
    /// Active label sorts first; otherwise by day-total desc, then alphabetical.
    func allLabelsBreakdown(for date: Date, includeArchived: Bool = false) -> [LabelTotal] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return [] }

        var allLabels = Set<String>()
        for entry in entries { allLabels.insert(entry.label) }
        if isRunning, !currentLabel.isEmpty { allLabels.insert(currentLabel) }

        var totals: [String: TimeInterval] = [:]
        for entry in entries {
            let s = max(entry.start, dayStart)
            let e = min(entry.end, dayEnd)
            guard s < e else { continue }
            totals[entry.label, default: 0] += e.timeIntervalSince(s)
        }
        if cal.isDateInToday(date), isRunning, !currentLabel.isEmpty, let rs = runningStart {
            let s = max(rs, dayStart)
            let e = min(Date(), dayEnd)
            if s < e { totals[currentLabel, default: 0] += e.timeIntervalSince(s) }
        }

        return allLabels
            .compactMap { (label: String) -> LabelTotal? in
                if !includeArchived && archivedLabels.contains(label) { return nil }
                return LabelTotal(label: label, total: totals[label] ?? 0)
            }
            .sorted { a, b in
                if a.total != b.total { return a.total > b.total }
                return a.label.lowercased() < b.label.lowercased()
            }
    }

    /// Number of task-start events that fall on the given day (includes the live
    /// one if it started today).
    func switchCount(for date: Date) -> Int {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return 0 }
        var count = entries.reduce(0) { sum, entry in
            sum + ((entry.start >= dayStart && entry.start < dayEnd) ? 1 : 0)
        }
        if isRunning, let rs = runningStart, rs >= dayStart, rs < dayEnd {
            count += 1
        }
        return count
    }

    /// Daily score: merges same-label segments into blocks, scores per `DailyScore`.
    func dailyScore(for date: Date) -> DailyScore {
        let segs = segments(on: date)

        // Merge same-label runs with <2 min gaps — coffee runs aren't switches.
        struct Block {
            let label: String
            let start: Date
            let end: Date
            var minutes: Double { end.timeIntervalSince(start) / 60 }
        }
        let mergeGap: TimeInterval = 120
        var blocks: [Block] = []
        for seg in segs {
            if let last = blocks.last, last.label == seg.label,
               seg.start.timeIntervalSince(last.end) < mergeGap {
                blocks[blocks.count - 1] = Block(
                    label: last.label, start: last.start, end: max(last.end, seg.end)
                )
            } else {
                blocks.append(Block(label: seg.label, start: seg.start, end: seg.end))
            }
        }

        var focusPoints = 0
        var deepBonus = 0
        var ultradianBonus = 0
        for block in blocks {
            let m = block.minutes
            if m >= 15 { focusPoints += min(6, Int(m / 15)) }
            if m >= 50 { deepBonus += 5 }
            if m >= 75 { ultradianBonus += 5 }
        }

        // Thrash: two short blocks (<10 min) within 30 min of each other.
        var switchPenalty = 0
        if blocks.count >= 2 {
            for i in 0..<(blocks.count - 1) {
                let a = blocks[i], b = blocks[i + 1]
                let gap = b.start.timeIntervalSince(a.end) / 60
                if a.minutes < 10, b.minutes < 10, gap < 30 {
                    switchPenalty -= 2
                }
            }
        }

        // Break cadence: gaps between blocks in the [5, 90] min sweet spot.
        var breakBonus = 0
        if blocks.count >= 2 {
            for i in 1..<blocks.count {
                let gap = blocks[i].start.timeIntervalSince(blocks[i - 1].end) / 60
                if gap >= 5, gap <= 90 { breakBonus += 3 }
            }
        }

        return DailyScore(
            focusPoints: focusPoints,
            deepBonus: deepBonus,
            ultradianBonus: ultradianBonus,
            breakBonus: breakBonus,
            switchPenalty: switchPenalty
        )
    }

    /// Longest single continuous entry on the day (clipped to day boundaries).
    func longestFocus(for date: Date) -> TimeInterval {
        segments(on: date).map(\.duration).max() ?? 0
    }

    func weeklyBreakdown(weekStart: Date, includeArchived: Bool = false) -> [LabelTotal] {
        let cal = Calendar.current
        guard let weekEnd = cal.date(byAdding: .day, value: 7, to: weekStart) else { return [] }
        let totals = Dictionary(grouping: segments(in: weekStart..<weekEnd), by: \.label)
            .mapValues { $0.reduce(0) { $0 + $1.duration } }
        return totals
            .compactMap { (label, total) -> LabelTotal? in
                if !includeArchived && archivedLabels.contains(label) { return nil }
                return LabelTotal(label: label, total: total)
            }
            .sorted { $0.total > $1.total }
    }

    // MARK: - Internal

    private func closeCurrentEntry() {
        guard let s = runningStart, !currentLabel.isEmpty else {
            runningStart = nil
            tickTask?.cancel()
            tickTask = nil
            clearRunningCheckpoint()
            return
        }
        entries.insert(TimeEntry(label: currentLabel, start: s, end: Date()), at: 0)
        runningStart = nil
        tickTask?.cancel()
        tickTask = nil
        clearRunningCheckpoint()
    }

    private func startTicker() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            var sinceCheckpoint = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.tickNow = Date()
                sinceCheckpoint += 1
                if sinceCheckpoint >= 60 {
                    self.saveRunningCheckpoint()
                    sinceCheckpoint = 0
                }
            }
        }
    }

    /// Persist the live entry's label/start/now to `running.json` so a hard kill
    /// (Xcode Stop, force quit, crash) loses at most ~1 min of the active segment.
    /// No-op when nothing is running.
    private func saveRunningCheckpoint() {
        guard let s = runningStart, !currentLabel.isEmpty else {
            clearRunningCheckpoint()
            return
        }
        let state = RunningState(label: currentLabel, start: s, lastCheckpoint: Date())
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: runningStoreURL, options: .atomic)
        } catch {
            print("running checkpoint save failed: \(error)")
        }
    }

    private func clearRunningCheckpoint() {
        try? FileManager.default.removeItem(at: runningStoreURL)
    }

    /// On launch, if a running checkpoint was left behind, fold it into `entries`
    /// as a closed entry ending at the last checkpoint. Worst-case loss is the
    /// gap between the last checkpoint and the kill (≤ ~1 min in steady state).
    private func restoreRunningIfAny() {
        guard let data = try? Data(contentsOf: runningStoreURL),
              let state = try? JSONDecoder().decode(RunningState.self, from: data),
              state.start < state.lastCheckpoint,
              !Self.isLegacyBreak(state.label)
        else {
            clearRunningCheckpoint()
            return
        }
        entries.insert(
            TimeEntry(label: state.label, start: state.start, end: state.lastCheckpoint),
            at: 0
        )
        save()
        clearRunningCheckpoint()
    }

    private func save() {
        do {
            let merged = mergedEntriesWithDisk()
            let data = try JSONEncoder().encode(merged)
            try data.write(to: storeURL, options: .atomic)
            if merged.count != entries.count { entries = merged }
        } catch {
            print("save failed: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let raw = (try? JSONDecoder().decode([TimeEntry].self, from: data)) ?? []
        // One-shot migration: drop legacy "Break" rows that older builds wrote
        // (overnight sleeps, explicit-break entries). Newer code never produces
        // them — break time is a gap, not a row. Persist the cleaned list so
        // the migration is idempotent: next load is a no-op.
        let cleaned = raw.filter { !Self.isLegacyBreak($0.label) }
        entries = cleaned
        if cleaned.count != raw.count,
           let encoded = try? JSONEncoder().encode(cleaned) {
            try? encoded.write(to: storeURL, options: .atomic)
        }
    }

    private static func isLegacyBreak(_ label: String) -> Bool {
        label.trimmingCharacters(in: .whitespaces)
            .caseInsensitiveCompare("Break") == .orderedSame
    }

    private func loadArchived() {
        guard let data = try? Data(contentsOf: archivedStoreURL),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return }
        archivedLabels = Set(list)
    }

    private func saveArchived() {
        if let data = try? JSONEncoder().encode(Array(archivedLabels).sorted()) {
            try? data.write(to: archivedStoreURL, options: .atomic)
        }
    }

    private func saveBreaths() {
        do {
            let merged = mergedBreathsWithDisk()
            let data = try JSONEncoder().encode(merged)
            try data.write(to: breathStoreURL, options: .atomic)
            if merged.count != breathEvents.count { breathEvents = merged }
        } catch {
            print("save breaths failed: \(error)")
        }
    }

    /// Union our in-memory entries with anything on disk by `id`, so a concurrent
    /// writer (rare — only possible during the brief window when a second copy starts)
    /// can't clobber data. Trades a small risk on concurrent deletes (a deleted label
    /// could be resurrected if another instance still has it) for safety on the
    /// dominant append-only path.
    private func mergedEntriesWithDisk() -> [TimeEntry] {
        guard let data = try? Data(contentsOf: storeURL),
              let onDisk = try? JSONDecoder().decode([TimeEntry].self, from: data)
        else { return entries }
        var seen = Set(entries.map(\.id))
        var merged = entries
        for e in onDisk where !seen.contains(e.id) {
            merged.append(e)
            seen.insert(e.id)
        }
        if merged.count == entries.count { return entries }
        // Newest first — matches insert(at: 0) used throughout.
        return merged.sorted { $0.start > $1.start }
    }

    private func mergedBreathsWithDisk() -> [BreathEvent] {
        guard let data = try? Data(contentsOf: breathStoreURL),
              let onDisk = try? JSONDecoder().decode([BreathEvent].self, from: data)
        else { return breathEvents }
        var seen = Set(breathEvents.map(\.id))
        var merged = breathEvents
        for e in onDisk where !seen.contains(e.id) {
            merged.append(e)
            seen.insert(e.id)
        }
        if merged.count == breathEvents.count { return breathEvents }
        return merged.sorted { $0.timestamp > $1.timestamp }
    }

    private func loadBreaths() {
        guard let data = try? Data(contentsOf: breathStoreURL) else { return }
        breathEvents = (try? JSONDecoder().decode([BreathEvent].self, from: data)) ?? []
    }
}
