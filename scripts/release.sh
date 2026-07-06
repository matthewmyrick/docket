#!/usr/bin/env bash
# Cut a release: run the local gates, tag the version from build.zig.zon,
# and push — .github/workflows/release.yml builds and publishes the binary.
#
# usage: scripts/release.sh
# The version to release is whatever build.zig.zon says; bump it first
# (its own commit) so tag, --version, and artifact names all agree.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*\.version = "\(.*\)".*/\1/p' build.zig.zon | head -1)
TAG="v$VERSION"

if [ -n "$(git status --porcelain)" ]; then
  echo "working tree not clean — commit or stash first" >&2
  exit 1
fi
if [ "$(git branch --show-current)" != "main" ]; then
  echo "releases are cut from main" >&2
  exit 1
fi
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "tag $TAG already exists — bump .version in build.zig.zon first" >&2
  exit 1
fi

echo "gates..."
zig fmt --check .
zig build test
zig build -Doptimize=ReleaseSafe
./zig-out/bin/ical-calendar-tui --version

git tag -a "$TAG" -m "ical-calendar-tui $TAG"
git push origin main "$TAG"

echo "pushed $TAG — release workflow is building:"
echo "  gh run watch --repo matthewmyrick/ical-calendar-tui"
