# TUI SURFACE NOTES

## OVERVIEW
`src/tui` owns the default interactive terminal surface plus explicit snapshot rendering for non-TTY use.

## STRUCTURE
```text
src/tui/
├── root.zig      # runtime state, bootstrap, input/event handling, snapshot path
├── render.zig    # frame/layout/render contracts; largest hot path
├── actions.zig   # action registry, key bindings, status hints
├── args.zig      # TUI/snapshot input-source parsing
├── terminal.zig  # PTY/terminal control, alternate screen cleanup
└── main.zig      # standalone `zig-scheduler-tui` entry
```

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| TTY vs snapshot behavior | `root.zig`, `args.zig` | Interactive requires real TTY; redirected output needs explicit source + `--snapshot`. |
| Layout and visual output | `render.zig` | Contract-sensitive and performance-sensitive. |
| Keyboard behavior | `actions.zig`, `root.zig` | Keep action registry as source of truth for keys/status hints. |
| Terminal cleanup | `terminal.zig`, `tools/tui_pty_exit_test.py` | Preserve alt-screen exit, cursor restore, final clear/home order. |
| Dashboard source cards | `root.zig`, `src/dashboard/root.zig` | Startup may eagerly simulate/load scenario entries. |

## CONVENTIONS
- Snapshot mode is explicit; do not make non-TTY dashboard mode silently render without an input source.
- Keep new key bindings in `actions.zig`; add or update duplicate-key tests when changing keys.
- Keep state mutations in `root.zig` narrow and localized; event/action branches already mix loading, simulation, selection, and redraw triggers.
- Audit complexity before changing `render.zig` or dashboard bootstrap; avoid per-frame scans/allocations over full traces/tasks when a cached or bounded pass works.
- When changing visible output, update direct render tests and CLI/TUI smoke expectations rather than relying only on manual screenshots.

## ANTI-PATTERNS
- Do not bypass `Terminal.deinit`/cleanup behavior; PTY tests assert leaving alternate screen before final clear/home.
- Do not add broad startup precompute unless it is deliberately accepted and bounded.
- Do not duplicate action labels/key summaries outside `actions.zig`.
- Do not treat `render.zig` as a dumping ground for runtime loading or simulator mutation; rendering should stay presentation-focused.

## VERIFY
```bash
zig build test --summary all
zig build tui -- --snapshot --scenario short-vs-long --policy fcfs --width 100 --height 30
python3 tools/tui_pty_exit_test.py zig-out/bin/zig-scheduler-tui
```
