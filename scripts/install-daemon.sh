#!/usr/bin/env bash
# Install the notification daemon under launchd (ARCHITECTURE.md §10):
# build ReleaseSafe, copy the binary to ~/.local/bin, render the plist into
# ~/Library/LaunchAgents, and bootstrap it. Re-running updates in place.
set -euo pipefail

cd "$(dirname "$0")/.."

LABEL="dev.matthewmyrick.ical-calendar-tui"
BIN_DIR="$HOME/.local/bin"
BIN="$BIN_DIR/ical-calendar-tui"
PLIST_SRC="launchd/$LABEL.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "building ReleaseSafe..."
zig build -Doptimize=ReleaseSafe

mkdir -p "$BIN_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
install -m 755 zig-out/bin/ical-calendar-tui "$BIN"
sed "s|__HOME__|$HOME|g" "$PLIST_SRC" > "$PLIST_DST"

# Reload if already running; TCC note: the calendar grant follows the binary
# identity, so the daemon may re-prompt after an update (README).
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"

echo "installed: $BIN"
echo "agent:     $PLIST_DST (label $LABEL)"
echo "logs:      ~/Library/Logs/ical-calendar-tui.log (set ICAL_TUI_DEBUG=1 for cycle lines)"
