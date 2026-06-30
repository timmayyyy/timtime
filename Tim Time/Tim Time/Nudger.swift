import Foundation

@MainActor
final class Nudger {
    // Static so it's never deallocated — keeps App Nap disabled for the process lifetime
    private static let appNapActivity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep,
        reason: "TimTime periodic check-in prompts"
    )

    private weak var tracker: Tracker?
    private let promptPanel = PromptPanel()
    /// One Task drives the whole 15/15/45 cadence. Predictable and
    /// rescheduleable; no two timers can ever race.
    private var cycle: Task<Void, Never>?
    /// True while the user is actively on a break — suppresses every
    /// cycle-driven prompt so nothing replaces the visible break view.
    private var onBreak = false
    /// True when the current break was started automatically (e.g. on wake from
    /// a short sleep) rather than by an explicit user choice. Only these
    /// self-correct: if the idle watchdog sees the user typing again, the break
    /// ends and the work picker opens. Breaks the user chose are left alone.
    private var breakWasAutoStarted = false

    /// Base tick — every 15m we surface a check-in. Whether it's a work check
    /// or the break/keep-working prompt is decided per-tick from how long it's
    /// been since the last real break.
    private let workInterval: TimeInterval = 15 * 60
    /// Once it's been this long since the last real break, every tick shows the
    /// break-or-keep-working prompt instead of a plain work check — and keeps
    /// showing it each tick until a break resets the clock. A firmer "stand up"
    /// nudge than the old once-per-cycle breath check.
    private let standUpThreshold: TimeInterval = Tracker.standUpThreshold

    func start(tracker: Tracker) {
        self.tracker = tracker
        _ = Self.appNapActivity
        tracker.onTaskStarted = { [weak self] in self?.handleTaskStarted() }
        scheduleCycle()
    }

    /// User started/switched a task → re-anchor the 15m work-check cadence to
    /// now, so a check-in doesn't fire moments after they begin. Exception: once
    /// a stand-up nudge is overdue (past `standUpThreshold` since the last
    /// break), keep the running cadence so repeated task switches can't keep
    /// deferring the break reminder.
    private func handleTaskStarted() {
        if let since = tracker?.timeSinceLastBreak, since >= standUpThreshold { return }
        scheduleCycle()
    }

    /// Restart the cycle from now — called after wake so a stale prompt
    /// queued before sleep doesn't surface immediately.
    func resetTimers() {
        onBreak = false
        scheduleCycle()
    }

    /// Cancel the cycle entirely — called before sleep so nothing fires
    /// mid-wake.
    func cancelTimers() {
        cycle?.cancel()
        cycle = nil
    }

    /// Surface the work prompt if nothing's running. No-op during a break or
    /// while a task is active.
    func promptIfIdle() {
        guard !onBreak, runningLabel == nil else { return }
        showWorkPrompt()
    }

    /// True while we're in an auto-started break that should yield the instant
    /// the user turns out to be active. The idle watchdog polls this.
    var isInAutoBreak: Bool { onBreak && breakWasAutoStarted }

    /// Called by the idle watchdog when it sees sustained input during an
    /// auto-started break: end the break and ask what they're working on, so a
    /// wrongly-assumed break self-corrects instead of silently accruing dead
    /// time. No-op for breaks the user chose deliberately. The break still
    /// counts (it's inferred from the work gap), we just stop assuming it.
    func endAutoBreakForActivity() {
        guard onBreak, breakWasAutoStarted else { return }
        onBreak = false
        breakWasAutoStarted = false
        promptPanel.close()
        showWorkPrompt()
        scheduleCycle()
    }

    /// One repeating 15m tick. Each tick surfaces either a work check-in or,
    /// once it's been `standUpThreshold` since the last real break, the
    /// break-or-keep-working prompt — repeating every tick until a break resets
    /// the clock. Anchored to user activity (restarted by `onTaskStarted`) and
    /// paused during a break (the `onBreak` guard; a break outcome reschedules a
    /// fresh cycle).
    private func scheduleCycle() {
        cycle?.cancel()
        let interval = workInterval
        cycle = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Int(interval)))
                if Task.isCancelled { return }
                guard let self else { return }
                if self.onBreak { return }
                self.tickPrompt()
            }
        }
    }

    /// Decide and show this tick's prompt: the break/keep-working prompt once
    /// the user has gone `standUpThreshold` without a real break, otherwise the
    /// work check-in. `timeSinceLastBreak` is nil when the user isn't actively
    /// working — there's nothing to stand up from, so fall through to the work
    /// prompt (which opens the picker if nothing's running).
    private func tickPrompt() {
        // Always the same check-in interface; `showWorkPrompt` grows the break
        // button on its own once a stand-up is overdue — no separate dialog.
        showWorkPrompt()
    }

    /// Show the standalone running-break timer, counting from `startAt` (use
    /// `Date()` for now, or an earlier date to pre-seed elapsed — e.g. backdated
    /// to when the Mac fell asleep). Used only for auto-started breaks; the
    /// decision-time break flow lives inside the work check-in.
    func showBreath(autoStartAt startAt: Date, autoStarted: Bool = false) {
        guard tracker != nil else { return }
        promptPanel.showBreath(
            startAt: startAt,
            onDone: { [weak self] in
                guard let self else { return }
                self.onBreak = false
                self.breakWasAutoStarted = false
                self.tracker?.logBreath(done: true)
                // Break finished → ask what's next and re-anchor the cycle.
                self.showWorkPrompt()
                self.scheduleCycle()
            },
            onBreakStart: { [weak self] in
                self?.onBreak = true
                self?.breakWasAutoStarted = autoStarted
                self?.tracker?.stop()
            }
        )
    }

    private func showWorkPrompt(startInPicker: Bool = false) {
        guard let tracker, !onBreak else { return }
        let breakOverdue = (tracker.timeSinceLastBreak ?? 0) >= standUpThreshold
        promptPanel.show(
            tracker: tracker,
            labels: tracker.labelsByRecency(),
            lastLabel: tracker.lastWorkedLabel,
            currentLabel: runningLabel,
            timeSinceLastBreak: tracker.timeSinceLastBreak,
            startInPicker: startInPicker,
            breakOverdue: breakOverdue,
            onBreath: { [weak self] done in
                guard let self else { return }
                self.onBreak = false
                self.tracker?.logBreath(done: done)
                if done {
                    self.showWorkPrompt()
                    self.scheduleCycle()
                }
            },
            onBreakStart: { [weak self] in
                self?.onBreak = true
                self?.breakWasAutoStarted = false
                self?.tracker?.stop()
            }
        ) { [weak self] label in
            self?.tracker?.start(label)
        }
    }

    private var runningLabel: String? {
        guard let t = tracker, t.isRunning, !t.currentLabel.isEmpty else { return nil }
        return t.currentLabel
    }
}
