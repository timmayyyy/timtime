import AppKit
import SwiftUI

// Screenshot harness. Renders TimTime's real SwiftUI views — compiled from the
// app's own sources, see build.sh — against invented data and a fixed clock.
//
//   usage: harness <output-dir> <menu-bar-icon.png>
//
// SAFETY: the Tracker reads and writes ~/Library/Application Support/TimTime.
// build.sh points CFFIXED_USER_HOME at a temp dir; (HOME alone does NOT move
// FileManager's Application Support.) Refuse to run if that didn't take, so
// this can never seed fake data into a real data folder.

let supportDir = try! FileManager.default.url(
    for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
guard supportDir.path.contains("/timtime-screens-") else {
    fatalError("refusing to run: app-support resolves to \(supportDir.path), not a scratch dir")
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let menuIconPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

NSApplication.shared.setActivationPolicy(.accessory)

// MARK: - Fake data

let cal = Calendar.current
/// Thursday 15 Oct 2026 — a fixed "today" so the week and month views are well
/// populated (Mon–Thu this week, two full weeks behind it).
let today = cal.date(from: DateComponents(year: 2026, month: 10, day: 15))!

func at(_ day: Date, _ h: Int, _ m: Int) -> Date {
    cal.date(bySettingHour: h, minute: m, second: 0, of: day)!
}

struct Block { let label: String; let start: Date; let end: Date }

enum Lbl {
    static let focus = ["Landing page redesign", "Q4 roadmap", "Write launch post"]
    static let meet = ["Team standup", "Client call", "1:1s"]
    static let admin = ["Email & Slack", "Invoices"]
    static let learn = ["Reading"]
}

struct SplitMix {
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(next() % UInt64(r.count)) }
}

/// A plausible workday: focus-heavy mornings, a lunch gap, meetings and admin
/// sprinkled in, the odd short break.
func generatedDay(_ day: Date, seed: UInt64, endHour: Int = 16) -> [Block] {
    var r = SplitMix(s: seed)
    var out: [Block] = []
    var cur = at(day, 8, 30).addingTimeInterval(TimeInterval(r.int(0...50) * 60))
    let lunchStart = at(day, 12, 10).addingTimeInterval(TimeInterval(r.int(0...25) * 60))
    let lunchLen = r.int(40...70)
    let end = at(day, endHour, 40).addingTimeInterval(TimeInterval(r.int(0...100) * 60))
    var lunched = false
    while cur < end {
        if !lunched && cur >= lunchStart {
            cur = cur.addingTimeInterval(TimeInterval(lunchLen * 60)); lunched = true; continue
        }
        let roll = r.int(0...99)
        let pool: [String]; let dur: ClosedRange<Int>
        switch roll {
        case ..<48: (pool, dur) = (Lbl.focus, 40...95)
        case ..<68: (pool, dur) = (Lbl.meet, 15...50)
        case ..<90: (pool, dur) = (Lbl.admin, 10...30)
        default: (pool, dur) = (Lbl.learn, 20...40)
        }
        var mins = r.int(dur)
        if !lunched {
            let toLunch = Int(lunchStart.timeIntervalSince(cur) / 60)
            if mins > toLunch + 5 { mins = max(10, toLunch) }
        }
        let e = cur.addingTimeInterval(TimeInterval(mins * 60))
        out.append(Block(label: pool[r.int(0...(pool.count - 1))], start: cur, end: min(e, end)))
        let gap = r.int(0...9) < 2 ? r.int(5...12) : r.int(1...2)
        cur = e.addingTimeInterval(TimeInterval(gap * 60))
    }
    return out
}

func seedBlocks(fullMonth: Bool = false) -> [Block] {
    var all: [Block] = []
    // Weekdays of October (fixed seeds, so the shots are reproducible). The
    // month scene gets the whole month; everything else stops at yesterday.
    let weekdays = [1, 2, 5, 6, 7, 8, 9, 12, 13, 14, 15, 16, 19, 20, 21, 22, 23, 26, 27, 28, 29, 30]
    for day in weekdays where fullMonth || day < 15 {
        let d = cal.date(from: DateComponents(year: 2026, month: 10, day: day))!
        all += generatedDay(d, seed: UInt64(10 + day), endHour: day == 9 ? 14 : 16)
    }
    if fullMonth { return all }
    // Today, hand-authored so the hero shot reads well. Running task starts 13:41.
    let t = today
    let todayBlocks: [(String, (Int, Int), (Int, Int))] = [
        ("Landing page redesign", (8, 55), (10, 13)),
        ("Email & Slack", (10, 16), (10, 31)),
        ("Team standup", (10, 33), (10, 48)),
        ("Q4 roadmap", (10, 50), (12, 2)),
        ("Email & Slack", (12, 4), (12, 25)),
        ("Invoices", (13, 30), (13, 41)),
    ]
    for b in todayBlocks {
        all.append(Block(label: b.0, start: at(t, b.1.0, b.1.1), end: at(t, b.2.0, b.2.1)))
    }
    return all
}

let runningLabel = "Write launch post"
let runningStart = at(today, 13, 41)

/// Fresh Tracker over a freshly seeded data dir, "running" since 13:41 and
/// showing `now`.
func makeTracker(now: Date, running: Bool = true, fullMonth: Bool = false) -> Tracker {
    let fm = FileManager.default
    let dir = supportDir.appendingPathComponent("TimTime", isDirectory: true)
    try? fm.removeItem(at: dir)
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)

    let entries = seedBlocks(fullMonth: fullMonth).map { TimeEntry(label: $0.label, start: $0.start, end: $0.end) }
    try! JSONEncoder().encode(entries).write(to: dir.appendingPathComponent("entries.json"))
    let breaths = [
        BreathEvent(timestamp: at(today, 10, 14), done: true),
        BreathEvent(timestamp: at(today, 10, 49), done: false),
        BreathEvent(timestamp: at(today, 12, 26), done: true),
    ]
    try! JSONEncoder().encode(breaths).write(to: dir.appendingPathComponent("breaths.json"))

    TTClock.now = running && !fullMonth ? runningStart : now
    let tracker = Tracker()
    if running && !fullMonth { tracker.start(runningLabel) }
    TTClock.now = now
    tracker.tickNow = now

    // Name four of the eight fixed colors and file the labels under them.
    let c = tracker.colorCategories
    let groups: [(Int, String, [String])] = [
        (0, "Deep work", Lbl.focus), (2, "Meetings", Lbl.meet),
        (5, "Admin", Lbl.admin), (1, "Learning", Lbl.learn),
    ]
    for g in groups {
        tracker.renameColorCategory(id: c[g.0].id, name: g.1)
        tracker.setColor(c[g.0].id, for: g.2)
    }
    return tracker
}

// MARK: - Offscreen rendering

@MainActor func pump(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

/// Host `view` in a real (but invisible) window, let it lay out, and grab it.
/// The window is alpha 0 on the main screen, so nothing flashes, but the view
/// still gets the Retina backing scale and a genuine AppKit layout pass.
@MainActor func snapshot<V: View>(_ view: V) async -> NSImage {
    let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
    // Prefer a Retina screen: layer-backed SwiftUI content (big numerals,
    // secondary text) is rasterized at the window's backing scale, and on a 1x
    // screen it comes out soft even when the bitmap is 2x.
    let screen = NSScreen.screens.first { $0.backingScaleFactor >= 2 } ?? NSScreen.main ?? NSScreen.screens[0]
    let origin = NSPoint(x: screen.frame.minX + 80, y: screen.frame.minY + 80)
    let win = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: 520, height: 1000)),
                       styleMask: [.borderless], backing: .buffered, defer: false)
    win.isOpaque = false
    win.backgroundColor = .clear
    win.hasShadow = false
    win.appearance = NSAppearance(named: .darkAqua)
    win.contentView = host
    win.alphaValue = 0
    win.orderFrontRegardless()
    await pump(500)
    host.layoutSubtreeIfNeeded()
    let size = host.fittingSize
    win.setContentSize(size)
    host.frame = NSRect(origin: .zero, size: size)
    await pump(700)
    host.layoutSubtreeIfNeeded()
    // An alpha-0 window reports a 1x backing scale, so make the 2x bitmap
    // ourselves: pixels = 2 × points, rep.size = points, and cacheDisplay
    // renders into it at Retina resolution.
    let scale = 2
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("no bitmap rep") }
    rep.size = size
    host.cacheDisplay(in: host.bounds, to: rep)
    print("  panel \(Int(size.width))x\(Int(size.height)) pt, \(rep.pixelsWide)x\(rep.pixelsHigh) px")
    let img = NSImage(size: size)
    img.addRepresentation(rep)
    win.orderOut(nil)
    return img
}

func writePNG<V: View>(_ view: V, name: String) {
    let r = ImageRenderer(content: view)
    r.scale = 2
    guard let cg = r.cgImage else { fatalError("render failed for \(name)") }
    let rep = NSBitmapImageRep(cgImage: cg)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: outDir.appendingPathComponent(name))
    print("wrote \(name)  \(cg.width)x\(cg.height)  \(data.count / 1024) KB")
}

// MARK: - Composition (desktop backdrop, menu bar)

struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.10, blue: 0.21),
                         Color(red: 0.22, green: 0.15, blue: 0.40),
                         Color(red: 0.52, green: 0.24, blue: 0.44)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(red: 0.35, green: 0.50, blue: 1).opacity(0.38), .clear],
                           center: UnitPoint(x: 0.15, y: 0.1), startRadius: 0, endRadius: 460)
            RadialGradient(colors: [Color(red: 1, green: 0.55, blue: 0.40).opacity(0.30), .clear],
                           center: UnitPoint(x: 0.9, y: 1.0), startRadius: 0, endRadius: 520)
        }
    }
}

struct MenuBarStrip: View {
    let title: String
    let running: Bool
    let icon: NSImage?
    let clock: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "applelogo")
            Spacer()
            HStack(spacing: 5) {
                if running {
                    Image(systemName: "stop.circle.fill")
                } else if let icon {
                    Image(nsImage: icon).renderingMode(.template).resizable().scaledToFit().frame(height: 14)
                }
                Text(title)
            }
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Color.white.opacity(0.20), in: RoundedRectangle(cornerRadius: 6))
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text(clock)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Color.black.opacity(0.30))
    }
}

/// Panel hanging under the menu bar in the top-right of a screen.
struct DeskScene: View {
    let panel: NSImage?
    let pill: NSImage?
    let width: CGFloat
    let height: CGFloat
    let strip: MenuBarStrip

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Wallpaper()
            VStack(spacing: 0) {
                strip
                HStack {
                    Spacer()
                    VStack(spacing: 0) {
                        if let panel {
                            Image(nsImage: panel).shadow(color: .black.opacity(0.5), radius: 22, y: 10)
                        }
                        if let pill {
                            Image(nsImage: pill).shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                        }
                    }
                }
                .padding(.trailing, 8).padding(.top, 8)
                Spacer(minLength: 0)
            }
        }
        .frame(width: width, height: height)
    }
}

/// Panel floating on the gradient — for screens where the menu bar is noise.
struct CardScene: View {
    let panel: NSImage
    var body: some View {
        ZStack {
            Wallpaper()
            Image(nsImage: panel).shadow(color: .black.opacity(0.5), radius: 24, y: 12).padding(46)
        }
        .frame(width: panel.size.width + 92, height: panel.size.height + 92)
    }
}

func menuBarLabel(_ label: String) -> String {
    guard label.count > 10 else { return label }
    let clipped = label.prefix(10).reversed().drop(while: \.isWhitespace).reversed()
    return String(clipped) + "…"
}

// MARK: - Scenes

@MainActor func runAll() async {
    let menuIcon = menuIconPath.flatMap { NSImage(contentsOfFile: $0) }
    let clockFmt = DateFormatter()
    clockFmt.dateFormat = "EEE MMM d  h:mm a"

    func menuView(_ t: Tracker) -> MenuView {
        MenuView(tracker: t, onDismiss: {}, welcomeBack: false, onSizeChange: { _ in })
    }
    func strip(_ now: Date, tracker: Tracker?) -> MenuBarStrip {
        if let t = tracker, t.isRunning {
            return MenuBarStrip(title: " \(menuBarLabel(t.currentLabel)) - \(t.todayTotal(for: t.currentLabel).hm)",
                                running: true, icon: menuIcon, clock: clockFmt.string(from: now))
        }
        return MenuBarStrip(title: " Break", running: false, icon: menuIcon, clock: clockFmt.string(from: now))
    }

    let calm = at(today, 14, 12)        // 42m since the last break: quiet one-liner
    let overdue = at(today, 14, 35)     // 65m: the prominent break card

    // 1 — hero: day view in context
    print("today")
    TTScene.mode = "day"; TTScene.selection = []
    var tracker = makeTracker(now: calm)
    var img = await snapshot(menuView(tracker))
    writePNG(DeskScene(panel: img, pill: nil, width: max(img.size.width + 160, 500),
                       height: img.size.height + 28 + 8 + 36, strip: strip(calm, tracker: tracker)),
             name: "today.png")

    // 2 — colors: shift-selected labels, ready to recolor / merge
    print("colors")
    TTScene.selection = ["Landing page redesign", "Write launch post"]
    tracker = makeTracker(now: calm)
    img = await snapshot(menuView(tracker))
    writePNG(CardScene(panel: img), name: "colors.png")
    TTScene.selection = []

    // 3 — week
    print("week")
    TTScene.mode = "week"
    tracker = makeTracker(now: calm)
    img = await snapshot(menuView(tracker))
    writePNG(CardScene(panel: img), name: "week.png")

    // 4 — month
    print("month")
    TTScene.mode = "month"
    tracker = makeTracker(now: at(cal.date(from: DateComponents(year: 2026, month: 10, day: 30))!, 17, 30),
                          running: false, fullMonth: true)
    img = await snapshot(menuView(tracker))
    writePNG(CardScene(panel: img), name: "month.png")

    // 5 — name colors
    print("name-colors")
    TTScene.mode = "colors"
    tracker = makeTracker(now: calm)
    img = await snapshot(menuView(tracker))
    writePNG(CardScene(panel: img), name: "name-colors.png")

    // 6 — break overdue: the prominent card
    print("break-nudge")
    TTScene.mode = "day"
    tracker = makeTracker(now: overdue)
    img = await snapshot(menuView(tracker))
    writePNG(CardScene(panel: img), name: "break-nudge.png")

    // 7 — the 30-minute "still on it?" check-in
    print("checkin")
    tracker = makeTracker(now: calm)
    img = await snapshot(ttMakePrompt(tracker: tracker, current: runningLabel, last: "Invoices",
                                      since: tracker.timeSinceLastBreak, overdue: tracker.isBreakOverdue))
    writePNG(DeskScene(panel: img, pill: nil, width: max(img.size.width + 160, 500),
                       height: img.size.height + 28 + 8 + 36, strip: strip(calm, tracker: tracker)),
             name: "checkin.png")

    // 8 — the break pill: nothing tracked, so it sits under the menu bar
    print("break-pill")
    tracker = makeTracker(now: calm, running: false)
    let pill = await snapshot(ttMakePill())
    writePNG(DeskScene(panel: nil, pill: pill, width: 500, height: 124,
                       strip: strip(calm, tracker: nil)),
             name: "break-pill.png")
}

Task { @MainActor in
    await runAll()
    print("done")
    exit(0)
}
NSApplication.shared.run()
