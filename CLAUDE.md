# TimTime

Minimalist macOS menu bar time tracker. SwiftUI, signed + notarized, Sparkle auto-updates.

## Project structure

```
Tim Time/Tim Time/          ← Xcode source root (synced folder)
  TimTimeApp.swift          ← @main App, MenuBarExtra scene, Sparkle updater
  MenuView.swift            ← Main popover: day switcher, input, breakdown, weekly chart
  Tracker.swift             ← Core state: start/stop, entries, sandbox-migration
  Nudger.swift              ← Single 15/15/45 cycle: work check at 15+30, breath at 45
  PromptView.swift          ← Floating NSPanel for check-in prompt
  Models.swift              ← TimeEntry, LabelTotal, TimeInterval formatters
  TimTime.entitlements      ← Sandbox OFF, network client ON (for Sparkle)
  Assets.xcassets           ← AppIcon (full-bleed, system-rounded), MenuBarIcon (template, monochrome)
Tim Time/Info.plist         ← Sparkle keys (SUFeedURL/SUPublicEDKey/SUEnableAutomaticChecks); INFOPLIST_FILE base, merged with generated keys
Tim Time/Tim Time.xcodeproj ← Xcode project (synced folder mode, no manual file refs needed)
Tim Time/scripts/release.sh ← archive → notarize → staple → DMG → Sparkle-sign
```

## Key design decisions

- **Menu bar only** — `LSUIElement = YES`, no Dock icon, pure `MenuBarExtra(.window)`
- **Append-only** — entries are never deleted, only added
- **Switch-to-start** — typing a label or clicking one auto-closes the current entry and starts a new one
- **Day clipping** — entries spanning midnight are clipped to day boundaries for accurate daily/weekly totals
- **Sandbox OFF** — data lives at `~/Library/Application Support/TimTime/entries.json`. Required for Sparkle 2 in-place updates (sandboxed Sparkle needs an XPC helper which isn't worth the complexity for an indie app). Hardened runtime + notarization carry the trust instead. A one-time auto-migration in `Tracker.init` copies data from the legacy container path (`~/Library/Containers/AI-Ascend.Tim-Time/...`) on first non-sandboxed launch.
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
