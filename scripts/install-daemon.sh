#!/usr/bin/env bash
# Install the notification daemon under launchd (ARCHITECTURE.md §10):
# build ReleaseSafe, copy the binary to ~/.local/bin, render the plist into
# ~/Library/LaunchAgents, and bootstrap it. Re-running updates in place.
set -euo pipefail

cd "$(dirname "$0")/.."

# macOS only: both this app and the `ical` CLI are built on EventKit.
if [ "$(uname)" != "Darwin" ]; then
  echo "this app is macOS-only (it reads the EventKit calendar store)" >&2
  exit 1
fi

# The `ical` CLI is a hard dependency: it handles all calendar writes
# (create/edit/RSVP) and is the fallback read source. Install it if missing.
if ! command -v ical >/dev/null 2>&1; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "the \`ical\` CLI is required and Homebrew isn't available to install it." >&2
    echo "install Homebrew (https://brew.sh) or install ical manually:" >&2
    echo "  brew tap BRO3886/tap && brew install ical" >&2
    exit 1
  fi
  echo "installing the ical CLI (required for creating/editing/RSVPing events)..."
  brew tap BRO3886/tap
  brew trust BRO3886/tap 2>/dev/null || true # newer brew requires trusting taps
  brew install ical
fi

LABEL="dev.matthewmyrick.docket"
BIN_DIR="$HOME/.local/bin"
BIN="$BIN_DIR/docket"
PLIST_SRC="launchd/$LABEL.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "building ReleaseSafe..."
zig build -Doptimize=ReleaseSafe

mkdir -p "$BIN_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
install -m 755 zig-out/bin/docket "$BIN"
sed "s|__HOME__|$HOME|g" "$PLIST_SRC" > "$PLIST_DST"

# Reload if already running; TCC note: the calendar grant follows the binary
# identity, so the daemon may re-prompt after an update (README).
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"

echo "installed: $BIN"
echo "agent:     $PLIST_DST (label $LABEL)"
echo "logs:      ~/Library/Logs/docket.log (set DOCKET_DEBUG=1 for cycle lines)"
