# TimTime

Minimalist macOS menu bar time tracker. SwiftUI, signed + notarized, Sparkle auto-updates.

## Project structure

```
Tim Time/Tim Time/          ← Xcode source root (synced folder)
  TimTimeApp.swift          ← @main App (empty Settings scene), AppDelegate: NSStatusItem + menu FloatingPanel, Sparkle updater; positionMenu caps panel at 80% screen height
  MenuView.swift            ← Main popover: day/week/month ViewMode, input, breakdown, charts, shift-select bar (color + N-way merge), Name Colors screen, pinned break button
  Tracker.swift             ← Core state: start/stop, entries, sandbox-migration, timeSinceLastBreak/isBreakOverdue; color palette + label→color map, mergeLabels/renameLabel, colorTotals
  Nudger.swift              ← Single 15/15/45 cycle: work check at 15+30, breath at 45
  PromptView.swift          ← FloatingPanel (NSPanel subclass) + PromptPanel controller for the check-in prompt
  PanelChrome.swift         ← Shared panel look (material/clip/border) + FixedSizeHostingView (the crash fix, see below)
  BreakButton.swift         ← Shared "Take a break" affordance (quiet one-liner ↔ prominent overdue card)
  BucketedLabelList.swift / LabelRow.swift ← Shared recency-bucketed picker rows (menu + prompt); LabelRow shows the category swatch, active-row tint, border-only selection
  DayOverview.swift / DayTimelineView.swift ← Day header + 24h timeline strip (color-coded, hover-to-spotlight)
  WeekTimelineView.swift    ← 7-day timeline strips (color-coded)
  MonthChartView.swift      ← Month = per-day 24h strips stacked with no gap (compact); hover for date + total
  ColorModel.swift          ← ColorCategory (fixed 8-color palette, names default empty), ColorTotal, Color.chartTrack
  ManageColorsView.swift    ← "Name Colors" screen: rename the fixed palette colors (no add/recolor/delete)
  Models.swift              ← TimeEntry, DaySegment, LabelTotal, LabelBucket, TimeInterval formatters
  TimTime.entitlements      ← Sandbox OFF, network client ON (for Sparkle)
  Assets.xcassets           ← AppIcon (full-bleed, system-rounded), MenuBarIcon (template, monochrome)
Tim Time/Info.plist         ← Sparkle keys (SUFeedURL/SUPublicEDKey/SUEnableAutomaticChecks); INFOPLIST_FILE base, merged with generated keys
Tim Time/Tim Time.xcodeproj ← Xcode project (synced folder mode, no manual file refs needed)
Tim Time/scripts/release.sh ← archive → notarize → staple → DMG → Sparkle-sign
```

## Key design decisions

- **Menu bar only** — `LSUIElement = YES`, no Dock icon. NOT `MenuBarExtra`: the SwiftUI scene is just `Settings { EmptyView() }`; `AppDelegate` builds an `NSStatusItem` and shows both surfaces (menu + check-in prompt) as custom borderless `FloatingPanel`s (NSPanel subclass) pinned to the screen's top-right. Done in AppKit for full control over left-click (panel) vs right-click (NSMenu) and right-edge pinning.
- **Panels size themselves; the hosting view must NOT** — ⚠️ macOS 26 crash class. An `NSHostingView` whose SwiftUI content changes size resizes its *window* from `-windowDidLayout` (via private `updateAnimatedWindowSize`), **inside** the CA-commit display cycle. That re-enters `-[NSWindow _postWindowNeedsUpdateConstraints]` and AppKit aborts the app ("Tim Time quit unexpectedly"). `sizingOptions = []` does NOT stop it (it only governs window min/max extrema — both build 8 and a container-wrapped subview still crashed). **Fix:** host content in `FixedSizeHostingView` (PanelChrome.swift), which (1) overrides `windowDidLayout` to a no-op (kills the auto-resize) and (2) reports the live content size via `onContentSize` each `layout()`. The owner then resizes the panel on the **next runloop turn** (`DispatchQueue.main.async` in `PromptPanel.applyContentSize` / `AppDelegate.positionMenu`) so the `setFrame` never reenters the layout pass. **Measuring the content is the catch:** with `sizingOptions = []` the SwiftUI `GeometryReader`/`PanelSizeKey` preference, `host.fittingSize`, and `host.intrinsicContentSize` all report **0×0**. Working measurements: `host.fittingSize` with `sizingOptions = [.intrinsicContentSize]` (what we use), or `NSHostingController.sizeThatFits(in:)`. The sizing setters guard against 0×0 so a stray 0 can't collapse the window.
- **One break affordance** — `BreakButton` (BreakButton.swift) is the single "Take a break" control shared by the check-in prompt and the pinned menu button. It escalates from a quiet one-liner to the prominent card on one shared rule: `Tracker.isBreakOverdue` (≥ `Tracker.standUpThreshold` = 45m), the same threshold the Nudger uses.
- **Append-only** — entries are never deleted, only added. Labels are plain strings on each entry (no first-class Label entity); rename/merge rewrite the `label` field in place across all entries + side-stores.
- **Switch-to-start** — typing a label or clicking one auto-closes the current entry and starts a new one
- **Day clipping** — entries spanning midnight are clipped to day boundaries for accurate daily/weekly totals. `segments(in: Range<Date>)` is the range-generic workhorse behind day/week/month + colorTotals.
- **Colors** — a fixed 8-color palette (`palette.json`, names default empty) plus a label→color map (`labelColors.json`), both mirroring the `archived.json` load/save pattern; migrated in `migrateFromContainerIfNeeded`. Assigned via shift-select (color one or many at once); `color(for:)`/`category(for:)` fall back to the first ("default") color. Charts key their fill on the label's category color; a label-row hover spotlights that label and dims the rest. `colorTotals(in:)` rolls up by category for the "By color" breakdown (with %). One-time `clearLegacyDefaultNames` blanks old built-in names (Blue/Green/…) while keeping user-chosen ones.
- **Panel height cap** — the floating panel has no AppKit height clamp of its own, so tall content (long label lists, month strips) would push the header under the menu bar. The scrollable lists cap themselves at ~80% of screen height via `.frame(maxHeight:)` (sized-to-content when short), and `positionMenu` hard-clamps panel height to the screen as a backstop. Never resize the panel synchronously — always via the deferred `onSizeChange`→`positionMenu` path (see the crash class above).
- **Sandbox OFF** — data lives at `~/Library/Application Support/TimTime/entries.json`. Required for Sparkle 2 in-place updates (sandboxed Sparkle needs an XPC helper which isn't worth the complexity for an indie app). Hardened runtime + notarization carry the trust instead. A one-time auto-migration in `Tracker.init` copies data from the legacy container path (`~/Library/Containers/AI-Ascend.Tim-Time/...`) on first non-sandboxed launch.
- **Never a keylogger — read *whether* input happened, never *what*** — a hard constraint, not a preference. The idle watchdog reads exactly two scalars, neither of which can carry content and neither of which needs a TCC permission: `HIDIdleTime` from the IORegistry (one integer, nanoseconds since the last HID event — it can't tell a keystroke from a mouse move, let alone which key) and `kAudioDevicePropertyDeviceIsRunningSomewhere` (a bool; never opens a stream, so no mic prompt and no orange dot). **Off the table permanently:** `CGEventTap`, `NSEvent` monitors with any *keyboard* mask, Accessibility/`AXUIElement`, screen recording, `CGWindowListCopyWindowInfo`. Entitlements stay sandbox-off + network-client only — nothing input-related. The one global monitor (`TimTimeApp.swift`, click-away dismissal) is masked to `.leftMouseDown/.rightMouseDown` and discards the event; mouse-only monitors need no Input Monitoring. Keep it that way.
- **Presence signals are weighted, and the weak one is capped** — the idle watchdog auto-stops a running entry after `awayIdleThreshold` (5m) of no input, backdating the end to the last real presence, so silence already means "break" (this is why reverting the old auto-break in `dd3464c` wouldn't help — that path only fired when *nothing* was tracked). Presence-without-input comes from two sources of very different quality: a live mic vouches indefinitely, while a display-sleep power assertion only vouches for `assertionPresenceCap` (45m) past the last real input. The assertion is held by browsers for a silent backgrounded video tab and by `coreaudiod` for days-old stale contexts — unbounded, it billed a 6-hour overnight entry as work. Audio *output* is not a usable tiebreaker; see the `displaySleepPrevented()` doc comment.
- **Deterministic prompt cycle** — `Nudger` runs a single Task: tick at +15m (work check), +30m (work check), +45m (breath). Anchored to user activity (`Tracker.onTaskStarted`), paused during breaks (`onBreak` guard), reset by both breath outcomes.
- **Swift 6 concurrency** — project uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY = YES`; avoid Timer closures that capture self across actor boundaries, prefer async Task loops
- **App icon = full-bleed** — macOS 26 (Tahoe) auto-masks every app icon to its own squircle and drops non-conforming art (a pre-shaped squircle with transparent margin) into a gray box at ~80% size. So `AppIcon` art must be **full-bleed, opaque, edge-to-edge** — no baked rounding/margin/shadow; the system does the rounding + glass. Layered sources for the proper cross-version Icon Composer `.icon` (background + foreground glyph + flat) live in `icon-composer-source/`. The installer DMG background is `scripts/dmg-background.png` (540×360).

## Build (dev)

Open `Tim Time/Tim Time.xcodeproj` in Xcode, hit Run. Deployment target macOS 14+ (`MACOSX_DEPLOYMENT_TARGET = 14.0`).
CLI builds work too (no Xcode UI needed): `xcodebuild -project "Tim Time/Tim Time.xcodeproj" -scheme "Tim Time" -configuration Debug -destination 'platform=macOS' build` — requires `xcode-select -p` to point at Xcode.app (not the bare Command Line Tools).

## One-time setup (do these in Xcode UI before first release)

1. **Add Sparkle** — File → Add Package Dependencies → `https://github.com/sparkle-project/Sparkle` → "Up to Next Major" from 2.6.0 → add to the Tim Time target.
2. **Flip sandbox off + wire entitlements**:
   - Target → Signing & Capabilities → remove "App Sandbox" capability (or just untick the sandbox box)
   - Build Settings → search "Entitlements" → set `CODE_SIGN_ENTITLEMENTS = Tim Time/TimTime.entitlements`
   - Build Settings → search "Hardened Runtime" → set `ENABLE_HARDENED_RUNTIME = YES`
3. **Add Sparkle Info.plist keys** — ⚠️ these are CUSTOM keys, so `INFOPLIST_KEY_*` build settings **do not work** (Xcode only emits Apple-defined keys that way and silently drops custom ones — you'll get a runtime "must specify SUFeedURL" error). They live in a real partial plist at `Tim Time/Info.plist`, wired via `INFOPLIST_FILE = Info.plist` while `GENERATE_INFOPLIST_FILE` stays `YES` (the build merges generated keys on top of this base). Keys:
   - `SUEnableAutomaticChecks` = `true`
   - `SUFeedURL` = appcast URL (e.g. `https://timmayyyy.github.io/timtime/appcast.xml`)
   - `SUPublicEDKey` = `<output from generate_keys>`
4. **Generate Sparkle EdDSA keypair (one-time)** — after step 1, build once so SPM artifacts land in DerivedData, then:
   ```
   find ~/Library/Developer/Xcode/DerivedData -name generate_keys -type f -exec {} \;
   ```
   Copy the printed public key into `SUPublicEDKey` (step 3). Private key stays in Keychain.
5. **Set up notary credentials (one-time)**:
   ```
   xcrun notarytool store-credentials TimTime-Notary \
     --apple-id YOU@example.com --team-id 6B42ZYWPK4 --password APP-SPECIFIC-PASSWORD
   ```
   (App-specific password from appleid.apple.com → Sign-In and Security → App-Specific Passwords.)
6. **Install create-dmg**: `brew install create-dmg`

## Release

```
cd "Tim Time"
./scripts/release.sh 1.1.0   # version arg optional; omit to use the current MARKETING_VERSION
```

Produces `Tim Time/build/TimTime.dmg` and prints an `<item>` block to paste into `appcast.xml`. Upload the DMG to your hosting (GitHub Releases recommended), paste the URL into the appcast `enclosure url=...`, commit and push the appcast.

## Data format

JSON files in `~/Library/Application Support/TimTime/`:
- `entries.json` — `[{id, label, start, end}]`, dates as `timeIntervalSinceReferenceDate`
- `breaths.json` — `[{id, timestamp, done}]`
- `running.json` — live entry's `{label, start, lastCheckpoint}` so a hard kill loses at most ~1 min
- `archived.json` — `[label, ...]` for hidden labels
- `palette.json` — `[{id, name, red, green, blue}]` fixed color categories (names default empty)
- `labelColors.json` — `{label: categoryUUID}` label→color assignments (absent ⇒ default/first color)
