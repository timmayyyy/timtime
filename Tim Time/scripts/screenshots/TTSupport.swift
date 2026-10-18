import Foundation

// Support for the screenshot harness. build.sh rewrites every `Date()` in the
// *copied* app sources to `TTClock.now` (and `isDateInToday` to
// `TTClock.isToday`), so the real views and the real Tracker can be rendered at
// a fixed, flattering moment regardless of when the script runs. The shipping
// sources are never modified.

enum TTClock {
    nonisolated(unsafe) static var now = Date()

    nonisolated static func isToday(_ d: Date) -> Bool {
        Calendar.current.isDate(d, inSameDayAs: now)
    }

    nonisolated static func isYesterday(_ d: Date) -> Bool {
        guard let y = Calendar.current.date(byAdding: .day, value: -1, to: now) else { return false }
        return Calendar.current.isDate(d, inSameDayAs: y)
    }
}

/// What MenuView should look like when it appears. The patched `onAppear`
/// reads these instead of resetting to the day view.
enum TTScene {
    nonisolated(unsafe) static var mode = "day"          // day | week | month | colors
    nonisolated(unsafe) static var selection: [String] = []
}
