# Adaptive Small-Terminal Layout Plan (Final Revised)

## Plan Summary
Adaptive support should land as **per-view layout branches backed by a shared `(view, tier) -> contract`**. This keeps `render.zig` and `root.zig` aligned while preserving the current `>=100x30` layout unchanged.

## Updated decision record
**Chosen:** per-view adaptive layouts with shared `LayoutTier` (`large`, `medium`, `compact`, `too_small`) and a shared contract for visible panes, default focus, and allowed actions.

**Alternatives considered fairly:**
1. **Explorer-only compact pass first** — attractive as the smallest first slice, but rejected as the final plan because it leaves `drawer`, `diff`, `picker`, and `help` falling back inconsistently once explorer can enter them at `80x24`.
2. **Per-view ad hoc branching with no shared contract** — attractive for speed, but rejected because `root.zig` focus cycling, `Enter`/`d`/`?`, and status hints would drift from what `render.zig` actually shows.
3. **Global responsive layout engine** — rejected for this milestone; too much framework churn before pane-priority rules are stable.

**Why this choice:** it is the smallest plan that fully solves the problem: supported compact tiers, explicit pane survival rules, exact root behavior, and an explicit `too_small` floor.

## Explorer spec
### Tier thresholds
- **large:** `>=100x30` — current layout unchanged
- **medium:** `90x26` to `99x29`
- **compact:** `80x24` to `89x25`
- **too_small:** `<80x24`

### Explorer / medium (`90x26`..`99x29`)
Visible panes:
1. `trace · cpu lanes` full width on top
2. bottom row: `tasks` | `events` | right stack of `tick` over `aggregate`

Behavior:
- Same four focus targets remain visible: `gantt`, `tasks`, `events`, `tick`
- `Tab` / reverse-`Tab` cycle those four only
- `Enter` opens drawer from task selection
- `d` opens diff
- Dense task table enabled

### Explorer / compact (`80x24`..`89x25`)
Visible panes in stacked order:
1. `trace · cpu lanes`
2. `tasks`
3. `events`
4. `tick`

**Stacked order means** one single-column vertical flow from top to bottom; each pane takes full usable width, later panes appear below earlier panes, and no hidden side-by-side pane remains focusable.

Compact content rules:
- `aggregate` pane is dropped as a standalone pane
- aggregate essentials move into `tick` footer/summary area
- focus targets remain `gantt`, `tasks`, `events`, `tick`
- `Tab` / reverse-`Tab` cycle only those visible targets
- `Enter` opens drawer as full-screen replacement
- `d` opens diff as full-screen replacement when compare data exists
- `?` opens full-screen single-column help

### Dense task table contract
**Medium:** keep current table structure but allow tighter widths.

**Compact:**
- **Keep columns:** `task`, `arr`, `burst`, `wait`, `resp`, `end`
- **Drop columns:** `w`, `group`, `dL`, `disp`, `turn`
- Preserve selection marker/row identity
- No fake `dense` flag; headers, widths, and row drawing must actually change

## Contract table (explicit minimum set)
| Tier / view | Visible panes | Default focus | Allowed actions | Notes |
| --- | --- | --- | --- | --- |
| explorer / medium | gantt, tasks, events, tick | current focus if still visible else `gantt` | `tab`, `backtab`, `enter`, `d`, `?`, scrub/play/theme/picker | aggregate still rendered, but not focusable |
| explorer / compact | gantt, tasks, events, tick | current focus if visible else `gantt` | `tab`, `backtab`, `enter`, `d`, `?`, scrub/play/theme/picker | panes stacked vertically; aggregate absorbed into tick summary |
| too_small / any view | none | none | `q`, resize recovery, optional theme toggle only if already global-safe | no drawer/diff entry; no pane cycling; explicit min-size message |

## Exact verification matrix
### Snapshot sizes
- `100x30` → large baseline
- `90x26` → medium baseline
- `80x24` → compact baseline
- `79x23` → too_small baseline

### Per-view snapshots
| View | 100x30 | 90x26 | 80x24 | 79x23 |
| --- | --- | --- | --- | --- |
| explorer | unchanged baseline snapshot | medium snapshot with 4 visible focus targets | compact stacked snapshot with gantt/tasks/events/tick only | too_small snapshot |
| drawer | current full snapshot | medium snapshot if layout differs, else baseline proof | compact full-screen stacked drawer snapshot | too_small snapshot |
| diff | current side-by-side baseline | medium side-by-side snapshot | compact stacked diff snapshot | too_small snapshot |
| picker | current baseline | medium snapshot | compact stacked list/detail snapshot | too_small snapshot |
| help | current overlay snapshot | medium overlay/full-screen snapshot as implemented | compact full-screen single-column snapshot | too_small snapshot or explicit disallow assertion |

### Root focus-contract tests
Add root-level tests that assert, per `(view, tier)` contract:
- hidden panes are never focusable
- `Tab` / reverse-`Tab` cycle only visible targets
- when the current focus becomes hidden after resize, focus normalizes to the contract default
- `Enter` from compact explorer with a selected task opens drawer
- `d` from compact explorer opens diff only when compare data exists
- `?` from compact explorer/help round-trips correctly

### Exact too_small assertions
At `<80x24` assert that:
- rendered output contains explicit minimum-size guidance for `80x24`
- no explorer panes are rendered/focusable
- `Tab` / reverse-`Tab` do nothing
- `Enter` does not open drawer
- `d` does not open diff
- status hints exclude pane-only actions

## Final recommendation
Proceed with **shared-contract per-view adaptation**, implemented in this order:
1. tier classifier + shared contract in `render.zig` / `root.zig`
2. explorer medium/compact layouts + real dense table
3. drawer/diff/picker/help compact branches using the same contract
4. exact snapshot + root-contract + too_small assertions

This gives a reviewable `80x24` design, keeps `>=100x30` stable, and avoids root/render behavior drift.
