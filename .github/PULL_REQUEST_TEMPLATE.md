## What

<!-- One or two sentences: what changes and why it's worth having. -->

## Checklist

- [ ] `zig fmt --check .` is clean
- [ ] `zig build test` is green (leak-checked; a leaking test is a failing test)
- [ ] I ran the TUI (`zig build run`), exercised my change, and quit with both `q`→`Q` and `Ctrl-C` — terminal restored both times
- [ ] New keys are in **all three**: the binding, the help overlay (`src/ui/help.zig`), and the README key table
- [ ] Behavior changes update `ARCHITECTURE.md` in the same PR
- [ ] No real calendar data anywhere (fixtures are synthetic — fake names, fake emails, fake meeting URLs)

## Release note

<!-- Merging to main auto-releases a patch bump. If this deserves a minor/major
bump, say so — the maintainer adds [release:minor]/[release:major] to the merge
commit. Docs-only changes skip releasing automatically. -->
