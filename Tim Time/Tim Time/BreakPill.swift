import SwiftUI
import AppKit

extension Notification.Name {
    /// Posted whenever a `FloatingPanel` surface (the menu or the check-in
    /// prompt) is shown or hidden. `AppDelegate` listens so the break pill can
    /// yield the top-right corner instead of rendering underneath them.
    static let timTimePanelVisibilityChanged = Notification.Name("TimTimePanelVisibilityChanged")

    static func postPanelVisibilityChanged() {
        NotificationCenter.default.post(name: .timTimePanelVisibilityChanged, object: nil)
    }
}

/// The pill's own window class — deliberately **not** a `FloatingPanel`.
///
/// Both `PromptPanel.present` and `AppDelegate.openMenu` treat "any visible
/// `FloatingPanel`" as a surface to bail on / tear down, because the menu and
/// the check-in prompt are mutually exclusive. The pill is long-lived and
/// coexists with neither rule, so making it a `FloatingPanel` would silently
/// suppress every check-in prompt for as long as a break lasted. A separate
/// type keeps it invisible to that logic; `AppDelegate` manages it explicitly.
final class BreakPillPanel: NSPanel {
    // Never takes focus — it's a passive indicator that happens to be clickable.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Small always-visible "Break" pill, pinned under the menu bar at the screen's
/// top-right. Shown whenever nothing is being tracked, so an unnoticed break
/// (idle auto-stop, a dismissed check-in, waking from sleep) can't quietly
/// swallow an afternoon. Clicking it opens the work picker.
@MainActor
final class BreakPill {
    private var panel: BreakPillPanel?
    private var onClick: (() -> Void)?

    var isVisible: Bool { panel?.isVisible == true }

    func show(onClick: @escaping () -> Void) {
        self.onClick = onClick
        // Already up — just refresh the handler, never rebuild (rebuilding would
        // flicker the pill on every tracker tick).
        guard panel == nil else { return }

        let content = BreakPillView(onTap: { [weak self] in self?.onClick?() })

        let initialSize = NSSize(width: 96, height: 30)
        let p = BreakPillPanel(
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
        // Visible on every Space and over full-screen apps — a break you can't
        // see while presenting is exactly the break you'd forget to end.
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // Same size-ownership contract as the other panels: SwiftUI must never
        // resize the window itself (see FixedSizeHostingView's doc comment —
        // that path is the macOS 26 crash), so we measure and apply deferred.
        let host = FixedSizeHostingView(rootView: AnyView(content))
        host.sizingOptions = [.intrinsicContentSize]
        host.onContentSize = { [weak self] size in self?.applyContentSize(size) }
        p.contentView = host

        panel = p
        position(p, size: initialSize)
        p.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func applyContentSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        // CRITICAL: hop to the next runloop turn. This lands inside the window's
        // display cycle; resizing synchronously reenters AppKit's layout and
        // aborts the app. Same rule as PromptPanel.applyContentSize.
        DispatchQueue.main.async { [weak self] in
            guard let self, let p = self.panel else { return }
            let cur = p.frame
            if abs(cur.width - size.width) < 0.5 && abs(cur.height - size.height) < 0.5 { return }
            self.position(p, size: size)
        }
    }

    /// Pin to the top-right of the visible frame (which already excludes the
    /// menu bar), so the pill sits just under it — the same corner the menu and
    /// prompt panels use, and where the user's eye already goes.
    private func position(_ p: NSPanel, size: CGSize) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let f = screen.visibleFrame
        let margin: CGFloat = 8
        let x = max(f.minX + margin, f.maxX - size.width - margin)
        let y = max(f.minY + margin, f.maxY - size.height - margin)
        p.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true, animate: false)
    }
}

private struct BreakPillView: View {
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Break")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            // Capsule rather than the shared `panelChrome` rounded-rect: this
            // reads as a badge, not a window, which is what keeps it tolerable
            // as a permanent fixture.
            .background(PanelMaterial())
            .background(Color.primary.opacity(hovering ? 0.10 : 0))
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("On a break — click to start tracking something")
        .fixedSize()
    }
}
