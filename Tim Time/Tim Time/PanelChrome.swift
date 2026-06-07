import SwiftUI
import AppKit

/// Shared `NSVisualEffectView` with the system menu material — used as the
/// background for both the menu panel and the work-prompt panel so they
/// render with the same stable translucency regardless of what's behind them.
struct PanelMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .menu
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension View {
    /// One consistent look for every floating panel: menu material + rounded
    /// clip + faint border. Apply right before any size-measurement
    /// `.background(GeometryReader ...)` so the geometry stays accurate.
    func panelChrome(cornerRadius: CGFloat = 12) -> some View {
        self
            .background(PanelMaterial())
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
    }

    /// Full panel container: pad, frame to width, apply chrome, and pipe
    /// SwiftUI's intrinsic size out via `onSizeChange` (used by the AppKit
    /// host to track size and reposition the NSPanel). Single source of
    /// truth for what a floating panel looks like.
    func panelContainer(width: CGFloat, onSizeChange: @escaping (CGSize) -> Void) -> some View {
        self
            .padding(14)
            .frame(width: width)
            .panelChrome()
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: PanelSizeKey.self, value: geo.size)
                }
            )
            .onPreferenceChange(PanelSizeKey.self) { onSizeChange($0) }
    }
}

extension View {
    /// Filter-field chrome shared by the menu and the prompt picker: borderless
    /// pill on a faint primary fill, no focus ring. The field is always
    /// effectively focused, so a separate "focused" state would just be noise.
    func filterFieldChrome() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(Color.primary.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct PanelSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// SwiftUI background that lets the user drag the containing NSWindow. Apply
/// to header areas — taps on overlaid SwiftUI controls (chevrons, buttons)
/// still hit their gestures first; only un-handled clicks fall through here.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragHandleView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class DragHandleView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
