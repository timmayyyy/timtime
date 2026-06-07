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

    /// Fixed interval — two of these are work check-ins, the third (at 45m)
    /// is the breath check. Replacing the old 10-15min random delay with a
    /// deterministic tick the user can predict.
    private let workInterval: TimeInterval = 15 * 60
    private let ticksPerCycle = 3

    func start(tracker: Tracker) {
        self.tracker = tracker
        _ = Self.appNapActivity
        tracker.onTaskStarted = { [weak self] in self?.scheduleCycle() }
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

    /// 15m → work check, 30m → work check, 45m → breath check. The breath
    /// outcome reschedules a fresh cycle so the next tick is always exactly
    /// 15m away — no drift, no overlapping signals.
    private func scheduleCycle() {
        cycle?.cancel()
        cycle = Task { @MainActor [weak self] in
            for tick in 1...3 {
                try? await Task.sleep(for: .seconds(Int(15 * 60)))
                if Task.isCancelled { return }
                guard let self else { return }
                if self.onBreak { return }
                if tick == self.ticksPerCycle {
                    self.showBreath(autoStartAt: nil)
                } else {
                    self.showWorkPrompt()
                }
            }
        }
    }

    /// Show the breath panel. `autoStartAt` non-nil skips the intro gate and
    /// starts the timer counting from that date (use `Date()` for now, or an
    /// earlier date to pre-seed elapsed).
    func showBreath(autoStartAt: Date?) {
        guard let tracker else { return }
        promptPanel.showBreath(
            timeSinceLastBreak: tracker.timeSinceLastBreak,
            currentLabel: runningLabel,
            autoStartAt: autoStartAt,
            onResult: { [weak self] done in
                guard let self else { return }
                self.onBreak = false
                self.tracker?.logBreath(done: done)
                // Break finished, or skipped with nothing running → ask what's next.
                self.showWorkPrompt()
                self.scheduleCycle()
            },
            onKeepWorking: { [weak self] in
                guard let self else { return }
                // Combined prompt: user chose to stay on the current task. Keep
                // it running, no follow-up "what are you working on?" picker —
                // just reschedule the next cycle.
                self.onBreak = false
                self.tracker?.logBreath(done: false)
                self.scheduleCycle()
            },
            onBreakStart: { [weak self] in
                self?.onBreak = true
                self?.tracker?.stop()
            }
        )
    }

    private func showWorkPrompt() {
        guard let tracker, !onBreak else { return }
        promptPanel.show(
            tracker: tracker,
            labels: tracker.labelsByRecency(),
            lastLabel: tracker.lastWorkedLabel,
            currentLabel: runningLabel,
            timeSinceLastBreak: tracker.timeSinceLastBreak,
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
