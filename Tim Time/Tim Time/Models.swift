import Foundation

struct TimeEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var label: String
    var start: Date
    var end: Date

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// One tracked work segment clipped to a query window. Source-agnostic — could
/// come from a stored TimeEntry or the live running entry. Pure value type, so
/// any aggregation built from `[DaySegment]` is a pure function.
struct DaySegment {
    let label: String
    let start: Date
    let end: Date
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

struct BreathEvent: Identifiable, Codable, Equatable {
    var id = UUID()
    var timestamp: Date
    var done: Bool
}

struct LabelTotal: Identifiable {
    var id: String { label }
    let label: String
    let total: TimeInterval
}

/// Daily productivity score, computed by `Tracker.dailyScore(for:)`.
struct DailyScore {
    /// +1 per 15 min of single-label work, capped at +6 per block.
    let focusPoints: Int
    /// +5 when a block crosses 50 min (deep-work threshold).
    let deepBonus: Int
    /// +5 when a block crosses 75 min (full ultradian cycle).
    let ultradianBonus: Int
    /// +3 per inter-block gap in [5, 90] min (microbreak sweet spot).
    let breakBonus: Int
    /// −2 per back-to-back pair of short (<10 min) blocks within 30 min.
    let switchPenalty: Int

    var total: Int {
        focusPoints + deepBonus + ultradianBonus + breakBonus + switchPenalty
    }
}

/// Snapshot of one label for picker/list views: most-recent activity, today's total,
/// and whether it's the currently-running label.
struct LabelEntry: Hashable, Identifiable {
    let label: String
    let lastSeen: Date
    let todayTotal: TimeInterval
    let isActive: Bool
    var id: String { label }
}

/// One row in the shared bucketed picker (`BucketedLabelList`). Both the menu
/// breakdown and the check-in prompt convert their domain data to this before
/// rendering.
struct PickerItem: Identifiable, Hashable {
    let label: String
    let total: TimeInterval
    let isActive: Bool
    let isSelected: Bool
    var isArchived: Bool = false
    var id: String { label }
}

/// One bucket section in the shared picker — bucket header + its rows.
struct PickerBucket: Identifiable {
    let bucket: LabelBucket
    let items: [PickerItem]
    var id: LabelBucket { bucket }
}

/// Recency bucket a label falls into, based on its most-recent activity timestamp.
/// Shared by the menu list and the check-in prompt so grouping is consistent.
enum LabelBucket: String, CaseIterable, Hashable {
    case today = "Today"
    case last24h = "Last 24h"
    case lastWeek = "Last week"
    case older = "Older"
    case archived = "Archived"

    static func bucket(for lastSeen: Date, now: Date = Date()) -> LabelBucket {
        let startOfToday = Calendar.current.startOfDay(for: now)
        if lastSeen >= startOfToday { return .today }
        if lastSeen >= now.addingTimeInterval(-24 * 3600) { return .last24h }
        if lastSeen >= now.addingTimeInterval(-7 * 24 * 3600) { return .lastWeek }
        return .older
    }
}

extension TimeInterval {
    var hms: String {
        let t = Int(self)
        return String(format: "%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }

    var hm: String {
        let t = Int(self)
        let h = t / 3600
        let m = (t % 3600) / 60
        let s = t % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        if s > 0 { return "\(s)s" }
        return "—"
    }
}
