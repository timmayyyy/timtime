import SwiftUI
import AppKit

// NSPanel defaults canBecomeKey to false, which would block keyboard input.
// Subclass to override — required for the text field to work. Non-private so
// AppDelegate can use it for the menu surface too.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// Only become key when a control genuinely needs first-responder status
    /// (e.g. the textfield). Without this, the first click on a label row
    /// activates the panel and a second click is needed to trigger the tap —
    /// the classic double-click-to-select bug on LSUIElement apps.
    override var becomesKeyOnlyIfNeeded: Bool {
        get { true }
        set {}
    }
    /// Keep all four edges inside the screen's visible area while dragging or
    /// programmatic resizing — borderless panels get no default chrome
    /// constraint, so without this override the user can drag the panel
    /// entirely off-screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        guard let s = screen ?? self.screen ?? NSScreen.main else { return frameRect }
        let f = s.visibleFrame
        var r = frameRect
        r.origin.x = max(f.minX, min(f.maxX - r.width, r.origin.x))
        r.origin.y = max(f.minY, min(f.maxY - r.height, r.origin.y))
        return r
    }
}

@MainActor
final class PromptPanel {
    private var panel: FloatingPanel?
    private var autoDismiss: DispatchWorkItem?

    func show(
        tracker: Tracker,
        labels: [LabelEntry],
        lastLabel: String?,
        currentLabel: String?,
        timeSinceLastBreak: TimeInterval?,
        onBreath: @escaping (Bool) -> Void,
        onBreakStart: @escaping () -> Void,
        onSubmit: @escaping (String) -> Void
    ) {
        let content = PromptContentView(
            tracker: tracker,
            labels: labels,
            lastLabel: lastLabel,
            currentLabel: currentLabel,
            timeSinceLastBreak: timeSinceLastBreak,
            onSubmit: { [weak self] label in
                onSubmit(label)
                self?.close()
            },
            onDismiss: { [weak self] in self?.close() },
            onBreath: { [weak self] done in
                // Done/Skip closes the panel; the parent then decides whether to
                // re-open a fresh work prompt (Done) or just stop (Skip).
                self?.close()
                onBreath(done)
            },
            onBreakStart: onBreakStart,
            onSizeChange: { [weak self] size in self?.applyContentSize(size) }
        )
        // Initial width matches the SwiftUI .frame(width:) the prompt picks for
        // its initial phase — no first-paint resize, no wobble.
        let width: CGFloat = currentLabel == nil ? 340 : 280
        present(AnyView(content), initialSize: NSSize(width: width, height: 400), autoDismissAfter: 300)
    }

    /// Resize the panel to match SwiftUI's intrinsic size. Maintains the user's
    /// dragged position (anchored by top edge) and clamps every edge inside
    /// the screen. `animate: false` because SwiftUI's own .animation on phase
    /// is the source of the visible transition — stacking AppKit's window
    /// resize on top causes the slow-cascading-grow effect.
    private func applyContentSize(_ size: CGSize) {
        guard let p = panel, size.width > 0, size.height > 0 else { return }
        let cur = p.frame
        if abs(cur.width - size.width) < 0.5 && abs(cur.height - size.height) < 0.5 { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        let f = screen?.visibleFrame ?? cur
        let margin: CGFloat = 8
        // Keep panel where the user dragged it; just anchor the top edge so a
        // height change grows downward rather than shifting the header.
        var x = cur.minX
        var y = cur.maxY - size.height
        x = max(f.minX + margin, min(f.maxX - size.width - margin, x))
        y = max(f.minY + margin, min(f.maxY - size.height - margin, y))
        p.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true, animate: false)
    }

    func showBreath(
        timeSinceLastBreak: TimeInterval?,
        currentLabel: String? = nil,
        autoStartAt: Date? = nil,
        onResult: @escaping (Bool) -> Void,
        onKeepWorking: @escaping () -> Void = {},
        onBreakStart: @escaping () -> Void
    ) {
        let content = BreathContentView(
            timeSinceLastBreak: timeSinceLastBreak,
            currentLabel: currentLabel,
            autoStartAt: autoStartAt,
            onDone: { [weak self] in
                self?.close()
                onResult(true)
            },
            onSkip: { [weak self] in
                self?.close()
                onResult(false)
            },
            onKeepWorking: { [weak self] in
                self?.close()
                onKeepWorking()
            },
            onStart: onBreakStart,
            onSizeChange: { [weak self] size in self?.applyContentSize(size) }
        )
        // Breath panel never auto-dismisses — only Skip or Done close it. The
        // user shouldn't have a stretch interrupted by the panel disappearing.
        present(AnyView(content), initialSize: NSSize(width: 260, height: 220), autoDismissAfter: 0)
    }

    func close() {
        autoDismiss?.cancel()
        autoDismiss = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func present(_ content: AnyView, initialSize: NSSize, autoDismissAfter seconds: TimeInterval) {
        // Don't stack on any other FloatingPanel that's already up — the
        // menu surface and the prompt are mutually exclusive. The next
        // scheduled fire will re-attempt.
        if NSApp.windows.contains(where: { $0 is FloatingPanel && $0.isVisible }) { return }
        if let key = NSApp.keyWindow, !(key is FloatingPanel) { return }

        let p = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        // .none rather than .utilityWindow — the fade-in stacks with SwiftUI's
        // first-paint layout and reads as the "weird slow open" wobble.
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        // Position top-right with the panel's initial size — SwiftUI's
        // onSizeChange refines the actual height a moment later.
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let f = screen.visibleFrame
            let margin: CGFloat = 8
            let x = max(f.minX + margin, f.maxX - initialSize.width - margin)
            let y = max(f.minY + margin, f.maxY - initialSize.height - margin)
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }

        p.contentView = NSHostingView(rootView: content)
        p.orderFrontRegardless()

        panel = p

        autoDismiss?.cancel()
        autoDismiss = nil
        if seconds > 0 {
            let work = DispatchWorkItem { [weak self] in self?.close() }
            autoDismiss = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }
}

// MARK: - Work check-in

private struct PromptContentView: View {
    @ObservedObject var tracker: Tracker
    let labels: [LabelEntry]
    let lastLabel: String?
    let currentLabel: String?
    let timeSinceLastBreak: TimeInterval?
    let onSubmit: (String) -> Void
    let onDismiss: () -> Void
    let onBreath: (Bool) -> Void
    let onBreakStart: () -> Void
    let onSizeChange: (CGSize) -> Void

    @State private var input = ""
    /// Set when the user clicks ✗ on confirm — switches to picker.
    @State private var showPicker = false
    /// True once the user taps Break? inline — switches to the breath timer.
    @State private var inBreath = false
    @State private var breathStartedAt: Date?
    @State private var breathNow: Date = Date()
    @State private var breathTicker: Task<Void, Never>?
    /// No-interaction timer. In confirm mode it just dismisses the popup
    /// (the user is presumed to be working). In picker mode it auto-breaks
    /// (nothing was running, presume the user is away).
    @State private var idleTask: Task<Void, Never>?
    /// Auto-break delay for the picker — user came back to a check-in but
    /// didn't engage, so flip to the breath view backdated by this much.
    private let idleCountdownSeconds: TimeInterval = 30
    /// Confirm mode is non-destructive: just close the popup after a long
    /// grace period so a heads-down user isn't punished for ignoring it.
    private let confirmAutoDismissSeconds: TimeInterval = 120
    /// Label currently hovered in the picker — DayOverview's timeline
    /// renders matching segments in green.
    @State private var hoveredLabel: String?
    @FocusState private var focused: Bool

    private enum Phase { case confirm, picker, breath }
    private var phase: Phase {
        if inBreath { return .breath }
        if currentLabel != nil && !showPicker { return .confirm }
        return .picker
    }

    private var trimmed: String { input.trimmingCharacters(in: .whitespaces) }
    private var isFiltering: Bool { !trimmed.isEmpty }
    private var inConfirmMode: Bool { phase == .confirm }

    /// After the user clicks ✗ ("no, not on this anymore"), don't re-suggest the
    /// just-rejected label as the pinned "continue" — that would be contradictory.
    private var effectiveLastLabel: String? {
        if showPicker, lastLabel == currentLabel { return nil }
        return lastLabel
    }

    /// Computed each render — the `.id(input)` on the ScrollView ensures the row
    /// list rebuilds cleanly on every keystroke, and computing eagerly here means
    /// the first paint already has the full list (no momentarily-short popover
    /// after the post-break transition).
    private var groups: [PickerBucket] { computeGroups() }

    private func computeGroups() -> [PickerBucket] {
        let now = Date()
        let q = trimmed.lowercased()
        let filtered: [LabelEntry] = isFiltering
            ? labels.filter { $0.label.lowercased().contains(q) }
            : labels

        let pinned = effectiveLastLabel
        var bucketed: [LabelBucket: [PickerItem]] = [:]
        for item in filtered {
            // Skip the pinned "continue" label when not filtering — it's shown above.
            if !isFiltering, item.label == pinned { continue }
            let b = LabelBucket.bucket(for: item.lastSeen, now: now)
            // Older labels only surface when the user is searching.
            if b == .older && !isFiltering { continue }
            bucketed[b, default: []].append(PickerItem(
                label: item.label,
                total: item.todayTotal,
                isActive: item.isActive,
                isSelected: false
            ))
        }

        return LabelBucket.allCases.compactMap { bucket in
            guard let items = bucketed[bucket], !items.isEmpty else { return nil }
            let sorted = items.sorted {
                $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
            }
            return PickerBucket(bucket: bucket, items: sorted)
        }
    }

    private var allMatches: [PickerItem] { groups.flatMap { $0.items } }

    private var headline: String {
        switch phase {
        case .confirm: return "Are you still working on?"
        case .picker:  return "What are you working on?"
        case .breath:  return breathStartedAt != nil ? "On break" : "Take a moment"
        }
    }

    private var breathElapsed: TimeInterval {
        guard let s = breathStartedAt else { return 0 }
        return breathNow.timeIntervalSince(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if phase == .breath {
                    Image(systemName: "wind").foregroundStyle(.blue)
                }
                Text(headline)
                    .font(.headline)
                    .id(headline)
                    .transition(.opacity)
                Spacer()
                if phase == .picker {
                    Text("Break?")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.blue)
                        .contentShape(Rectangle())
                        .onTapGesture { startBreath() }
                        .padding(.trailing, 4)
                }
            }
            .background(WindowDragArea())
            .animation(.easeInOut(duration: 0.25), value: headline)

            ZStack {
                switch phase {
                case .confirm: confirmView.transition(.opacity)
                case .picker:  pickerView.transition(.opacity)
                case .breath:  breathView.transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: phase)
        }
        .panelContainer(width: phase == .picker ? 340 : 280, onSizeChange: onSizeChange)
        .onAppear {
            if !inConfirmMode {
                DispatchQueue.main.async { focused = true }
            }
            startIdleTimer()
        }
        .onChange(of: showPicker) { _, newValue in
            // ✗ click → user is engaged. Stop the idle countdown and refocus.
            cancelIdleTimer()
            if newValue { DispatchQueue.main.async { focused = true } }
        }
        .onChange(of: input) { _, _ in cancelIdleTimer() }
        .onDisappear {
            breathTicker?.cancel()
            cancelIdleTimer()
        }
        .onExitCommand {
            if phase != .breath { onDismiss() }
        }
    }

    @ViewBuilder
    private var confirmView: some View {
        VStack(spacing: 8) {
            // Current task — large label with ✓ (confirm) and ✗ (switch to
            // picker) icons on the right. ✓ just closes the prompt; the
            // running entry's checkpoint is handled by Tracker's per-minute
            // ticker.
            HStack(spacing: 10) {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text(currentLabel ?? "")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.green)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)

                Button { showPicker = true } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(Color.green.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Break is now opt-in — no auto-trigger ring. Confirm mode just
            // auto-dismisses (keeps tracking) so a heads-down user isn't
            // accidentally pushed onto a break.
            Button(action: startBreath) {
                HStack {
                    Text("Break")
                        .font(.body)
                        .foregroundStyle(Color.blue)
                    Spacer()
                }
                .padding(.vertical, 12).padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .background(Color.blue.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var breathView: some View {
        BreathTimer(elapsed: breathElapsed) { onBreath(true) }
    }

    /// User tapped Break? — enter breath phase with timer at 0.
    private func startBreath() {
        enterBreath(startedAt: Date())
    }

    /// Idle ring filled (30s of no prompt interaction) — switch to the breath
    /// phase. The ring's visible fill makes this consent-driven: the user saw
    /// it ticking and chose not to dismiss the prompt.
    private func autoBreak() {
        enterBreath(startedAt: Date().addingTimeInterval(-idleCountdownSeconds))
    }

    private func enterBreath(startedAt: Date) {
        cancelIdleTimer()
        breathStartedAt = startedAt
        breathNow = Date()
        inBreath = true
        onBreakStart()
        breathTicker?.cancel()
        breathTicker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                breathNow = Date()
            }
        }
    }

    private func startIdleTimer() {
        idleTask?.cancel()
        switch phase {
        case .breath:
            return
        case .confirm:
            // User is working. Don't auto-break — just close the popup after
            // a long grace period. Next check-in (10–15m) will reopen it.
            idleTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(confirmAutoDismissSeconds))
                if Task.isCancelled { return }
                onDismiss()
            }
        case .picker:
            // Nothing was running — user opened (or got served) the picker
            // but didn't pick a task. Presume away → auto-break.
            idleTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(idleCountdownSeconds))
                if Task.isCancelled { return }
                autoBreak()
            }
        }
    }

    private func cancelIdleTimer() {
        idleTask?.cancel()
        idleTask = nil
    }

    @ViewBuilder
    private var pickerView: some View {
        VStack(alignment: .leading, spacing: 12) {
            DayOverview(tracker: tracker, date: Date(), highlightedLabel: hoveredLabel)

            TextField("e.g. Sales, Admin...", text: $input)
                .focused($focused)
                .onSubmit(submit)
                .filterFieldChrome()

            if !isFiltering, let last = effectiveLastLabel {
                Button { onSubmit(last) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .foregroundStyle(Color.accentColor)
                        Text(last)
                            .font(.callout.weight(.semibold))
                        Spacer()
                        Text("continue")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(Color.accentColor.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }

            if !groups.isEmpty {
                ScrollView {
                    BucketedLabelList(
                        groups: groups,
                        onTap: onSubmit,
                        onArchiveToggle: nil,
                        onHoverChanged: { hoveredLabel = $0 },
                        highlightedLabel: isFiltering ? allMatches.first?.label : nil
                    )
                    .padding(.trailing, 2)
                }
                .id(input)
                .frame(minHeight: isFiltering ? 100 : 0, maxHeight: 420)
            } else if isFiltering {
                Text("No matches for “\(trimmed)”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
            }
        }
    }

    private func submit() {
        let t = trimmed
        if t.isEmpty {
            if let last = effectiveLastLabel { onSubmit(last) }
            return
        }
        // Pick the top filtered row (the one highlighted in the UI) if there
        // is one; otherwise start a new label from the typed text.
        if let first = allMatches.first {
            onSubmit(first.label)
            return
        }
        onSubmit(t)
    }
}

// MARK: - Small panel UI

/// Filled-arc countup for the Break button. `filled` 0.0 → 1.0 — the stroke
/// fills clockwise as the idle timer runs; complete arc = auto-break fires.
private struct CountdownRing: View {
    let filled: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.blue.opacity(0.25), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0, min(1, filled)))
                .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 14, height: 14)
    }
}

/// Shared "break in progress" pill: elapsed time on the left, ✓ icon on
/// the right. Same shape as the confirm view's current-task pill for
/// visual consistency. Used by the inline breath phase of the work prompt
/// and the standalone breath reminder once started.
private struct BreathTimer: View {
    let elapsed: TimeInterval
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(elapsed.hms)
                .font(.title3.weight(.semibold).monospacedDigit())
            Spacer()
            Button(action: onDone) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.green)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Color.blue.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct BreathContentView: View {
    let timeSinceLastBreak: TimeInterval?
    /// The task running when the prompt appeared, if any. When set, the intro
    /// offers "Keep working on X" so the break decision is a single prompt
    /// instead of breath → separate "what are you working on?" picker.
    let currentLabel: String?
    /// nil → show the OK/Skip intro gate. Non-nil → skip the gate and start
    /// the timer counting from this date (use a past date to pre-seed elapsed).
    let autoStartAt: Date?
    let onDone: () -> Void
    let onSkip: () -> Void
    /// User chose to stay on the current task — dismiss without a follow-up picker.
    let onKeepWorking: () -> Void
    let onStart: () -> Void
    let onSizeChange: (CGSize) -> Void

    @State private var startedAt: Date?
    @State private var now: Date = Date()
    @State private var ticker: Task<Void, Never>?
    /// Idle timer for the intro gate — auto-starts the break if the user
    /// doesn't engage, same pattern as the confirm view's countdown ring.
    @State private var idleTask: Task<Void, Never>?
    @State private var breakProgress: Double = 0
    @State private var countdownActive = false
    private let idleCountdownSeconds: TimeInterval = 30

    private var hasStarted: Bool { startedAt != nil }
    private var elapsed: TimeInterval {
        guard let s = startedAt else { return 0 }
        return now.timeIntervalSince(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "wind").foregroundStyle(.blue)
                Text(hasStarted ? "On break" : "Time for a break?")
                    .font(.headline)
                Spacer()
            }
            .background(WindowDragArea())

            if hasStarted {
                BreathTimer(elapsed: elapsed, onDone: onDone)
            } else {
                // Two clear single-click choices. With a task running this folds
                // the old breath → "what are you working on?" two-step into one:
                // take a break, or keep the current task going.
                Button { startBreath() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "wind")
                        Text("Take a break")
                            .font(.body.weight(.semibold))
                        Spacer()
                        if currentLabel == nil {
                            CountdownRing(filled: breakProgress)
                                .opacity(countdownActive ? 1 : 0)
                        }
                    }
                    .foregroundStyle(Color.blue)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity)
                    .background(Color.blue.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)

                if let label = currentLabel {
                    Button {
                        cancelIdleTimer()
                        onKeepWorking()
                    } label: {
                        HStack(spacing: 8) {
                            Circle().fill(Color.green).frame(width: 8, height: 8)
                            Text("Keep working on \(label)")
                                .font(.body)
                                .lineLimit(1)
                            Spacer()
                            CountdownRing(filled: breakProgress)
                                .opacity(countdownActive ? 1 : 0)
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity)
                        .background(Color.green.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        cancelIdleTimer()
                        onSkip()
                    } label: {
                        HStack {
                            Text("Not now")
                                .font(.body)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }

                if let secs = timeSinceLastBreak {
                    Text("\(secs.hm) since last break")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .panelContainer(width: 260, onSizeChange: onSizeChange)
        .onAppear {
            if let at = autoStartAt, startedAt == nil {
                startBreath(at: at)
            } else if startedAt == nil {
                startIdleTimer()
            }
        }
        .onDisappear {
            ticker?.cancel()
            cancelIdleTimer()
        }
    }

    private func startBreath(at: Date = Date()) {
        cancelIdleTimer()
        startedAt = at
        now = Date()
        onStart()
        ticker?.cancel()
        ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                now = Date()
            }
        }
    }

    /// Mirrors PromptContentView's idle countdown: if the user doesn't engage
    /// with the intro within 30s, assume they've walked away and start the
    /// break with elapsed time backdated to when the ring began filling.
    private func startIdleTimer() {
        idleTask?.cancel()
        breakProgress = 0
        countdownActive = true
        withAnimation(.linear(duration: idleCountdownSeconds)) { breakProgress = 1 }
        idleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(idleCountdownSeconds))
            if Task.isCancelled { return }
            if currentLabel != nil {
                // A task is running and the user didn't engage — likely heads-down.
                // Keep working rather than stopping their task on a break.
                onKeepWorking()
            } else {
                // Nothing running — presume away → start the break, backdated.
                startBreath(at: Date().addingTimeInterval(-idleCountdownSeconds))
            }
        }
    }

    private func cancelIdleTimer() {
        idleTask?.cancel()
        idleTask = nil
        countdownActive = false
        breakProgress = 0
    }
}
