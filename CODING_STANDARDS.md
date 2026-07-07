# Zig Coding Standards — docket

These rules are **binding** for all code in this repository. They exist to keep
a systems-language codebase safe, readable, and memory-predictable when
multiple agents/sessions work on it. When a rule and convenience conflict, the
rule wins; if a rule is genuinely wrong for a case, change the rule in this
file *in the same commit* with a sentence of justification.

---

## 1. Toolchain & formatting

- **Pinned toolchain.** The Zig version lives in `.zigversion` and
  `build.zig.zon` (`minimum_zig_version`). Never develop on a different
  version "just to try" — Zig minor versions break code. Upgrades are their
  own commit: bump both files, fix fallout, note the version in the message.
- **`zig fmt` is law.** Every commit is `zig fmt --check .` clean. No manual
  alignment, no style debates — the formatter decides.
- **Zero build warnings.** A warning is a bug you haven't met yet.
- **Dependencies are pinned by hash** in `build.zig.zon` (use
  `zig fetch --save …`). Adding a dependency requires justification in the
  commit body. Target dependency count: **1** (libvaxis). The standard
  library is vast — check it before reaching for a package.

## 2. Naming & file organization

Follow the Zig standard library conventions exactly:

| Thing | Style | Example |
|---|---|---|
| Types (struct/enum/union) | `TitleCase` | `CalendarSource`, `Rsvp` |
| Functions & methods | `camelCase` | `fetchEvents`, `drawMonthGrid` |
| Variables, fields, constants | `snake_case` | `poll_interval`, `lead_times` |
| Files & directories | `snake_case.zig` | `ical_cli.zig`, `statusbar.zig` |
| Namespace-only structs | file itself is the struct where idiomatic |

- One concern per file; files over ~400 lines are a smell — split by concern,
  not by line count.
- `pub` is an API contract. Everything is private until something outside the
  file needs it. Reviewers may ask "why is this pub?" — have an answer.
- No abbreviations that save under three characters (`cal` is fine as a
  domain word; `evt`, `cfg`, `mgr` are not).

## 3. Memory & allocators (the heart of this project)

1. **Every allocating function takes an `Allocator` parameter.** No hidden
   global allocators, no allocating in `init` without the caller passing the
   allocator. Grep-test: `std.heap.` appears only in `main.zig`, `poller.zig`
   (arena creation), and tests.
2. **Ownership is documented at the signature.** Every function that returns
   allocated memory says who frees it and how, in its doc comment:
   `/// Result is owned by `arena`; freed when the snapshot is dropped.`
3. **Arenas for phase-shaped lifetimes.** Snapshot data lives in the
   snapshot's `ArenaAllocator` and is freed wholesale. If you write a manual
   `free` for anything inside a snapshot, the design is broken — stop.
4. **The draw path does not allocate.** Per-frame formatting uses a
   `FixedBufferAllocator` scratch reset each frame. `std.fmt.bufPrint` over
   `allocPrint` in UI code, always.
5. **Debug allocator with leak detection.** `main` in debug builds wraps
   allocations in `GeneralPurposeAllocator(.{})` and `defer`-checks
   `.deinit() == .ok`. Tests use `std.testing.allocator` (leak-checked by
   the framework) — a leaking test is a failing test.
6. **`defer`/`errdefer` at acquisition.** Resource acquired → cleanup deferred
   on the *next line*, before any code that can fail. This includes the error
   path: `errdefer` anything a later failure would strand.
7. **No `undefined` beyond immediate initialization.** `var buf: [N]u8 =
   undefined;` immediately followed by a bounded write is fine; `undefined`
   struct fields "filled in later" are not.
8. **Bounded everything.** Buffers, event windows, attendee lists we render,
   dedup log size — every unbounded input gets an explicit cap with a named
   constant.

## 4. Error handling

- **Explicit error sets on public functions.** `pub fn fetch(...) FetchError![]Event`,
  never `anyerror` in a public signature. Inferred sets (`!T`) are acceptable
  for private helpers.
- **Errors are values; handle or propagate deliberately.** `try` is for
  propagation you *chose*; `catch` must either handle meaningfully or add
  context — never `catch {}` to silence (the one exception: best-effort
  cleanup paths, commented `// best-effort`).
- **The UI never crashes on data problems.** Fetch/parse failures degrade:
  keep the previous snapshot, set a status message. `panic`/`unreachable`
  are reserved for *programmer invariants* ("enum switch is exhaustive"),
  never for I/O, parsing, subprocess, or permission failures.
- **Error messages name the actor and the fix.** Not `error: parse failed`
  but `ical output parse failed at byte 214 — run 'ical list -o json' to
  inspect; using cached events`.

## 5. Optionals, slices, and sentinels

- `?T` for absence — never magic values (`-1`, empty-string-means-missing is
  allowed **only** in the C ABI boundary structs, converted to `?[]const u8`
  or documented-empty immediately on the Zig side).
- Slices (`[]const u8`) over many-pointers everywhere except the shim
  boundary. Convert C pointers to slices at the boundary, immediately, with
  their lengths.
- `unwrap`-style `.?` only when a comment or the previous line proves
  presence; otherwise `orelse` with a real fallback or error.

## 6. comptime

- Use comptime for what it's for: the theme table, the video-link provider
  table, key-binding tables, exhaustive-switch guarantees.
- Do **not** build comptime type gymnastics for the source interface — a
  tagged union with two variants beats a generic vtable factory. This
  codebase optimizes for the next reader, not for demonstrating Zig.

## 7. C / Objective-C interop (the shim)

- `native/eventkit_shim.h` is the **only** interop surface. Zig code outside
  `src/calendar/eventkit.zig` must not `@cImport` anything.
- The C ABI carries only: `int` error codes, `double` unix timestamps,
  `char* + len` UTF-8 buffers. No ObjC types, no structs with hidden layout
  assumptions, no callbacks (blocking calls are fine — the caller is the
  poller thread).
- Every shim function's contract (who allocates, who frees, thread
  expectations) is documented **in the header**, and `ek_free` frees anything
  the shim returns.
- The Zig wrapper converts to Zig types (slices, errors, optionals) at the
  boundary; raw C values never travel further inland.
- ObjC memory: the shim uses ARC (compile with `-fobjc-arc`); buffers
  returned across the ABI are `malloc`ed copies, freed by `ek_free`.

## 8. Concurrency

- **Two threads, one mutex, one wake event.** UI thread + poller thread; the
  mutex guards the snapshot pointer (held by the UI across draw+render, see
  ARCHITECTURE.md §4); an `std.Io.Event` with `waitTimeout` wakes the poller early for
  manual refresh / shutdown (Zig 0.16's `std.Io` has no condvar `timedWait`;
  the Event is the idiomatic equivalent). That is the complete concurrency
  design. Any addition requires updating ARCHITECTURE.md §4 first.
- Data crossing threads is **immutable after publish** (the snapshot). No
  atomics-as-cleverness; no lock-free anything.
- Shutdown is orderly: set `should_quit`, signal condvar, `join` the poller,
  then deinit vaxis (restoring the terminal), then free arenas. Ctrl-C goes
  through the same path (vaxis delivers it as an event) — never `exit()` with
  the terminal in raw mode.

## 9. Testing

- `zig build test` runs all tests; it must pass on every commit.
- Tests live **in the file they test** (`test "video link detection" { … }`)
  — Zig's convention keeps them honest and close.
- **Separate logic from I/O** so logic is testable: date math (month grids,
  week starts, "same weekday next week"), JSON→Event parsing (fed from
  `testdata/*.json` fixtures), notification-window/dedup decisions, and
  video-link detection are pure functions with table-driven tests.
- I/O edges (subprocess, shim, sinks) are thin and get integration smoke
  tests behind a `zig build itest` step (may require a machine with calendar
  access; must not run in default `zig build test`).
- Date/time tests pass explicit timestamps — **never** `std.time.timestamp()`
  in a test expectation. Include DST-transition and month-boundary cases;
  time bugs are this project's most likely bug class.

## 10. Documentation

- `//!` module doc at the top of every file: what this module owns, one
  paragraph.
- `///` doc comments on every `pub` decl — contract, ownership, thread
  expectations if relevant.
- Comments explain **constraints and why**, not what the next line does.
  `// EKEventStore must outlive all fetches — see ARCHITECTURE.md §5b` is good;
  `// increment i` is deleted on sight.
- When behavior diverges from ARCHITECTURE.md, update ARCHITECTURE.md in the same commit.

## 11. Zig idiom quick-list

- `const` by default; `var` only when mutated.
- Prefer `for (items) |item|` / `while` with payload captures over index math.
- Exhaustive `switch` on enums — no `else` arm on our own enums (the compiler
  then catches every new variant).
- `std.debug.print` never ships: UI text goes through vaxis, diagnostics go
  through a tiny `log.zig` wrapper over `std.log` (silenced in TUI mode,
  stderr in `--daemon`/`--agenda`).
- Integer casts are explicit and checked: `@intCast` where narrowing is
  proven safe (comment the proof), `std.math.cast` + handling where not.
- Timestamps are `i64` unix seconds UTC throughout; conversion to local
  calendar dates happens in exactly one module (`src/calendar/time.zig` if
  needed) — timezone logic must not be scattered.
