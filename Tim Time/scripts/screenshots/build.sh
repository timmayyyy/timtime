#!/bin/bash
# Regenerate the marketing screenshots from the app's real SwiftUI views,
# using invented data (no real entries are read or shown).
#
#   ./scripts/screenshots/build.sh [output-dir]      # default: ../screenshots
#
# How it works: copies the app sources to a scratch dir, patches the COPIES
# (fixed clock, no idle watchdog/nudger, flat panel background, scene hooks),
# compiles them with main.swift, and runs the result with CFFIXED_USER_HOME
# pointed at a scratch dir so the Tracker's data folder is NOT your real one.
# The shipping sources are never modified. Needs no Screen Recording permission.
#
# If a patch below stops matching after a refactor, the script fails loudly
# rather than producing stale-looking shots — update the pattern.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/../../Tim Time"                       # Swift sources
OUT="${1:-$HERE/../../../screenshots}"
WORK="$(mktemp -d /tmp/timtime-screens-XXXXXX)"  # name is checked by main.swift
SRC="$WORK/src"
mkdir -p "$SRC" "$WORK/home" "$OUT"
OUT="$(cd "$OUT" && pwd)"

echo "▸ copying sources → $SRC"
for f in "$APP"/*.swift; do
  case "$(basename "$f")" in TimTimeApp.swift) continue ;; esac   # @main + Sparkle
  cp "$f" "$SRC/"
done
cp "$HERE/TTSupport.swift" "$HERE/main.swift" "$SRC/"

# must_patch <file> <perl-substitution> <description>
must_patch() {
  local file="$SRC/$1" expr="$2" what="$3"
  local before after
  before="$(shasum "$file")"
  perl -0pi -e "$expr" "$file"
  after="$(shasum "$file")"
  [ "$before" != "$after" ] || { echo "✗ patch did not apply: $what ($1)"; exit 1; }
}

echo "▸ patching copies"
# 1. Fixed clock: every Date() / isDateInToday in the app code reads TTClock.
for f in "$SRC"/*.swift; do
  case "$(basename "$f")" in main.swift|TTSupport.swift) continue ;; esac
  perl -0pi -e 's/\bDate\(\)/TTClock.now/g; s/\b(?:Calendar\.current|cal)\.isDateInToday\(/TTClock.isToday(/g; s/\b(?:Calendar\.current|cal)\.isDateInYesterday\(/TTClock.isYesterday(/g' "$f"
done
# 2. No background machinery in the Tracker: idle watchdog, nudger, launch prompt.
must_patch Tracker.swift 's/^\s*startIdleWatchdog\(\)\n//m' "idle watchdog call"
must_patch Tracker.swift 's/^\s*nudger\.start\(tracker: self\)\n//m' "nudger start"
must_patch Tracker.swift 's/self\?\.nudger\.promptIfIdle\(\)/_ = self/' "launch prompt"
must_patch Tracker.swift 's/\@Published private\(set\) var tickNow/\@Published var tickNow/' "tickNow setter"
# 3. Flat, opaque stand-in for the NSVisualEffectView panel material (a
#    behind-window blur can't render offscreen).
must_patch PanelChrome.swift 's/func makeNSView\(context: Context\) -> NSVisualEffectView \{.*?\n    \}\n/func makeNSView(context: Context) -> NSView {\n        let v = NSView(); v.wantsLayer = true\n        v.layer?.backgroundColor = NSColor(calibratedRed: 0.165, green: 0.160, blue: 0.172, alpha: 1).cgColor\n        return v\n    }\n/s' "PanelMaterial.makeNSView"
must_patch PanelChrome.swift 's/updateNSView\(_ nsView: NSVisualEffectView,/updateNSView(_ nsView: NSView,/' "PanelMaterial.updateNSView"
# 4. Let the harness pick the MenuView scene instead of always resetting to Day.
must_patch MenuView.swift 's/viewMode = \.day\n(\s*)showColorManager = false\n\s*resetSelection\(\)/viewMode = TTScene.mode == "week" ? .week : (TTScene.mode == "month" ? .month : .day)\n$1showColorManager = TTScene.mode == "colors"\n$1selection = TTScene.selection/' "MenuView.onAppear scene hook"
# 5. Entry points to the two file-private views.
cat >> "$SRC/PromptView.swift" <<'EOF'

@MainActor func ttMakePrompt(tracker: Tracker, current: String, last: String?,
                             since: TimeInterval?, overdue: Bool) -> some View {
    PromptContentView(
        tracker: tracker, labels: tracker.labelsByRecency(), lastLabel: last,
        currentLabel: current, timeSinceLastBreak: since, startInPicker: false,
        breakOverdue: overdue, onSubmit: { _ in }, onDismiss: {}, onBreakStart: {},
        onRequestKey: {}, onSizeChange: { _ in })
}
EOF
cat >> "$SRC/BreakPill.swift" <<'EOF'

@MainActor func ttMakePill() -> some View { BreakPillView(onTap: {}) }
EOF

echo "▸ compiling"
swiftc -swift-version 5 -Onone \
  -Xfrontend -default-isolation -Xfrontend MainActor \
  "$SRC"/*.swift -o "$WORK/harness" 2>&1 | grep -v "warning:" | grep -E "error|\.swift" | head -40 || true
[ -x "$WORK/harness" ] || { echo "✗ compile failed (full log: re-run swiftc by hand in $SRC)"; exit 1; }

echo "▸ rendering → $OUT"
ICON="$APP/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon@3x.png"
CFFIXED_USER_HOME="$WORK/home" "$WORK/harness" "$OUT" "$ICON"

rm -rf "$WORK"
echo "✓ done"
