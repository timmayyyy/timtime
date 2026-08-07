import SwiftUI
import AppKit
import Combine
import ServiceManagement
#if canImport(Sparkle)
import Sparkle
#endif

@main
struct TimTimeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No visible scenes — the menu bar surface is built by AppDelegate so we
        // get full control over left-click (panel) vs right-click (NSMenu) and
        // can pin the panel to the screen's right edge with a fixed margin.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let tracker = Tracker()

    private var statusItem: NSStatusItem!
    private var menuPanel: FloatingPanel?
    private var menuClickMonitor: Any?
    /// The "Break" badge shown under the menu bar whenever nothing is tracked.
    private let breakPill = BreakPill()
    /// Last size we asked the menu panel to be. SwiftUI's onPreferenceChange
    /// fires repeatedly during the resize animation — tracking the requested
    /// size short-circuits the loop.
    private var lastRequestedMenuSize: NSSize = .zero
    private var cancellables = Set<AnyCancellable>()
    #if canImport(Sparkle)
    /// Sparkle's standard controller — owns the update checker, schedules
    /// background checks per Info.plist (SUEnableAutomaticChecks), and powers
    /// the "Check for Updates…" menu item.
    private let updater = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    #endif

    override init() {
        super.init()
        // Single-instance guard — two copies would race on entries.json.
        if let bundleID = Bundle.main.bundleIdentifier {
            let me = ProcessInfo.processInfo.processIdentifier
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != me }
            if let existing = others.first {
                existing.activate()
                exit(0)
            }
        }
        try? SMAppService.mainApp.register()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        tracker.onWakePrompt = { [weak self] in
            Task { @MainActor in self?.openMenu(welcomeBack: true) }
        }

        tracker.objectWillChange
            .sink { [weak self] in
                Task { @MainActor in
                    self?.refreshStatusItem()
                    self?.refreshBreakPill()
                }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshStatusItem() }
            }
            .store(in: &cancellables)
        // The prompt/menu panels claim the same corner, so re-evaluate the pill
        // whenever one opens or closes.
        NotificationCenter.default.publisher(for: .timTimePanelVisibilityChanged)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshBreakPill() }
            }
            .store(in: &cancellables)
        refreshStatusItem()
        refreshBreakPill()
    }

    /// The pill is up exactly when nothing is being tracked and no other surface
    /// owns the top-right corner. Deliberately keyed on `isRunning` rather than
    /// the Nudger's explicit break flag: the states the user actually misses are
    /// the implicit ones (idle auto-stop, a dismissed check-in, a wake from
    /// sleep), and "not tracking" covers all of them — the same condition that
    /// already drives the menu bar's "Break" text.
    private func refreshBreakPill() {
        let otherSurfaceUp = NSApp.windows.contains { $0 is FloatingPanel && $0.isVisible }
        if tracker.isRunning || otherSurfaceUp {
            breakPill.hide()
        } else {
            breakPill.show { [weak self] in
                guard let self else { return }
                self.breakPill.hide()
                self.tracker.pickTaskFromBreakPill()
            }
        }
    }

    // MARK: - Status item click handling

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            toggleMenu()
        }
    }

    private func toggleMenu() {
        if menuPanel?.isVisible == true {
            closeMenu()
        } else {
            openMenu(welcomeBack: false)
        }
    }

    /// Show the menu as a borderless `FloatingPanel` pinned to the screen's
    /// top-right with a fixed margin. Same `NSHostingView` + size-via-preference
    /// pattern as the work-prompt panel, so both surfaces read consistently.
    private func openMenu(welcomeBack: Bool) {
        closeMenu()  // ensure clean state
        // Close any other FloatingPanel that may be up (typically the periodic
        // check-in prompt) so we don't render both on top of each other.
        for w in NSApp.windows where w is FloatingPanel && w.isVisible {
            w.orderOut(nil)
        }

        // Initial size matches MenuView's outer .frame(width:) for the day
        // view it opens into — no first-paint resize, so no animation wobble.
        let initialSize = NSSize(width: 340, height: 500)

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
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        // Position top-right of the status item's screen. Subsequent size
        // changes go through positionMenu (anchored top-edge + clamped).
        if let screen = statusItem?.button?.window?.screen ?? NSScreen.main {
            let f = screen.visibleFrame
            let margin: CGFloat = 8
            let x = f.maxX - initialSize.width - margin
            let y = f.maxY - initialSize.height - margin
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }
        lastRequestedMenuSize = initialSize
        menuPanel = p

        let menuRoot = MenuView(
            tracker: tracker,
            onDismiss: { [weak self] in self?.closeMenu() },
            welcomeBack: welcomeBack,
            onSizeChange: { [weak self] size in
                guard let self, let panel = self.menuPanel else { return }
                self.positionMenu(panel, size: size)
            }
        )
        // Same approach as the prompt panel: FixedSizeHostingView suppresses
        // SwiftUI's crashing window auto-resize and reports the live content's
        // fitting size via onContentSize, which positionMenu applies deferred.
        let host = FixedSizeHostingView(rootView: AnyView(menuRoot))
        host.sizingOptions = [.intrinsicContentSize]
        host.onContentSize = { [weak self] size in
            guard let self, let panel = self.menuPanel else { return }
            self.positionMenu(panel, size: size)
        }
        p.contentView = host
        p.orderFrontRegardless()
        Notification.Name.postPanelVisibilityChanged()
        if !welcomeBack {
            // Manual opens activate so the textfield takes keystrokes. Auto-opens
            // (wake) skip activation so the panel dismisses cleanly on click-away.
            NSApp.activate(ignoringOtherApps: true)
        }

        // Click anywhere outside the app → close. (Global monitor doesn't fire
        // for clicks inside our own windows, so typing/clicking labels is fine.)
        menuClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.closeMenu()
        }
    }

    /// Resize the panel to match SwiftUI's intrinsic size. Maintains the user's
    /// dragged position (anchored by top edge so a height change grows down
    /// rather than shifting the header). Clamps every edge inside the screen.
    private func positionMenu(_ p: NSPanel, size: NSSize) {
        // Ignore the SwiftUI GeometryReader's 0×0 reports — only real content
        // sizes (from FixedSizeHostingView.onContentSize) should size the panel.
        guard size.width > 0, size.height > 0 else { return }
        if abs(size.width - lastRequestedMenuSize.width) < 0.5
            && abs(size.height - lastRequestedMenuSize.height) < 0.5 { return }
        lastRequestedMenuSize = size
        // CRITICAL: defer out of SwiftUI's layout pass (see applyContentSize in
        // PromptView). A synchronous setFrame from .onPreferenceChange reenters
        // AppKit window layout during the CA commit and aborts the app.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.menuPanel === p else { return }
            let screen = self.statusItem?.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
            guard let f = screen?.visibleFrame else { return }
            let margin: CGFloat = 8
            // Safety clamp: the panel can never be taller than the screen. The
            // SwiftUI lists cap themselves to 80% and scroll internally, so this
            // only bites in pathological cases — and prevents the header being
            // shoved under the menu bar when it does.
            let h = min(size.height, f.height - margin * 2)
            let cur = p.frame
            var x = cur.minX
            var y = cur.maxY - h
            x = max(f.minX + margin, min(f.maxX - size.width - margin, x))
            y = max(f.minY + margin, min(f.maxY - h - margin, y))
            p.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: NSSize(width: size.width, height: h)), display: true, animate: false)
        }
    }

    private func closeMenu() {
        if let m = menuClickMonitor {
            NSEvent.removeMonitor(m)
            menuClickMonitor = nil
        }
        menuPanel?.orderOut(nil)
        menuPanel = nil
        lastRequestedMenuSize = .zero
        Notification.Name.postPanelVisibilityChanged()
    }

    // MARK: - Right-click NSMenu

    private func showContextMenu() {
        // If the panel was open, the global monitor already closed it. Make sure.
        closeMenu()

        let menu = NSMenu()

        let about = NSMenuItem(title: "About TimTime", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())

        let showTask = UserDefaults.standard.object(forKey: "showTaskInTitle") as? Bool ?? true
        let titleItem = NSMenuItem(
            title: "Show task in menu bar",
            action: #selector(toggleShowTaskInTitle),
            keyEquivalent: ""
        )
        titleItem.target = self
        titleItem.state = showTask ? .on : .off
        menu.addItem(titleItem)

        let showArchived = UserDefaults.standard.bool(forKey: "showArchived")
        let archivedItem = NSMenuItem(
            title: "Show archived labels",
            action: #selector(toggleShowArchived),
            keyEquivalent: ""
        )
        archivedItem.target = self
        archivedItem.state = showArchived ? .on : .off
        menu.addItem(archivedItem)

        menu.addItem(.separator())

        #if canImport(Sparkle)
        let updates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        updates.target = self
        menu.addItem(updates)
        if let last = updater.updater.lastUpdateCheckDate {
            let fmt = RelativeDateTimeFormatter()
            fmt.unitsStyle = .full
            let checked = NSMenuItem(
                title: "Last checked \(fmt.localizedString(for: last, relativeTo: Date()))",
                action: nil,
                keyEquivalent: ""
            )
            checked.isEnabled = false
            menu.addItem(checked)
        }
        menu.addItem(.separator())
        #endif

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // Attach temporarily so the next click opens the menu; detach after so
        // future left-clicks still hit the panel instead of the menu.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleShowTaskInTitle() {
        let cur = UserDefaults.standard.object(forKey: "showTaskInTitle") as? Bool ?? true
        UserDefaults.standard.set(!cur, forKey: "showTaskInTitle")
    }

    @objc private func toggleShowArchived() {
        let cur = UserDefaults.standard.bool(forKey: "showArchived")
        UserDefaults.standard.set(!cur, forKey: "showArchived")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    #if canImport(Sparkle)
    @objc private func checkForUpdates() {
        updater.checkForUpdates(nil)
    }
    #endif

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "TimTime",
            .credits: NSAttributedString(
                string: "Minimalist menu-bar time tracking.",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
        ])
    }

    // MARK: - Menu bar title

    /// Menu bar space is scarce and shared with every other status item, so the
    /// task name is clipped to `menuBarLabelLimit` characters. An ellipsis marks
    /// the clip (one character, and without it "Serve Fund" reads like the whole
    /// label). Trailing whitespace is trimmed first so we never emit "Serve …".
    static let menuBarLabelLimit = 10
    static func menuBarLabel(_ label: String) -> String {
        guard label.count > menuBarLabelLimit else { return label }
        let clipped = label.prefix(menuBarLabelLimit)
            .reversed().drop(while: \.isWhitespace).reversed()
        return String(clipped) + "…"
    }

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        if tracker.isRunning {
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: nil)
        } else {
            let img = NSImage(named: "MenuBarIcon")
            img?.isTemplate = true
            button.image = img
        }
        button.imagePosition = .imageLeading

        // Running: task + today total. Idle: "Break" so the user always
        // knows the app's state (and doesn't think the app silently broke
        // when a check-in auto-dismissed or sleep paused tracking).
        let showTask = UserDefaults.standard.object(forKey: "showTaskInTitle") as? Bool ?? true
        if showTask {
            if tracker.isRunning, !tracker.currentLabel.isEmpty {
                let total = tracker.todayTotal(for: tracker.currentLabel)
                button.title = " \(Self.menuBarLabel(tracker.currentLabel)) - \(total.hm)"
            } else {
                button.title = " Break"
            }
        } else {
            button.title = ""
        }
    }
}
